defmodule Zaq.People.IdentityResolver do
  @moduledoc """
  Resolves trusted channel senders and message authors to ZAQ Person identities.

  Channel ingress uses this before dispatching an agent event so downstream
  consumers receive a stable, JSON-safe actor shape:

      %{person: %{id: id, full_name: full_name, team_ids: team_ids}}

  On any error, callers should keep the message unresolved.
  """

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.Bridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.Audience
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.NodeRouter
  alias Zaq.People.Resolver
  alias Zaq.Repo

  @type person_payload :: %{id: integer(), full_name: String.t() | nil, team_ids: [integer()]}

  @doc "Resolves a verified connector sender, enriching discovery through its channel profile."
  @spec resolve_channel_sender(map()) :: {:ok, Person.t()} | {:error, :unauthorized}
  def resolve_channel_sender(scope) do
    with {:ok, platform, sender, config_id} <- channel_sender(scope),
         {:ok, %Person{status: "active"} = person} <-
           discover_channel_sender(platform, sender, config_id,
             profile_context: Map.get(scope, :profile_context)
           ) do
      {:ok, person}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Checks a literal active Person against existing connector identity without discovering a new Person."
  @spec authorize_channel_sender(term(), map()) :: :ok | {:error, :unauthorized}
  def authorize_channel_sender(%Person{id: id}, scope) do
    with {:ok, platform, sender, config_id} <- channel_sender(scope),
         {:ok, %Person{id: ^id, status: "active"}} <-
           People.match_by_channel(platform, sender, config_id) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_channel_sender(_person, _scope), do: {:error, :unauthorized}

  defp channel_sender(%{channel_config_id: id, sender_id: sender} = scope)
       when is_integer(id) and id > 0 and is_binary(sender) do
    with true <- String.trim(sender) != "",
         {:ok, config} <- fetch_connector(scope, Map.get(scope, :provider), true) do
      {:ok, config.provider, sender, id}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp channel_sender(_scope), do: {:error, :unauthorized}

  defp discover_channel_sender(platform, sender, config_id, opts) do
    case match_author(platform, sender, config_id) do
      {:ok, %{incomplete: false} = person} ->
        {:ok, person}

      {:error, :identity_scope_changed} = error ->
        error

      _ ->
        profile = maybe_enrich(platform, sender, %{"channel_id" => sender}, config_id, opts)
        discover_person(platform, profile, config_id)
    end
  end

  @spec resolve(Incoming.t(), keyword()) :: {:ok, Zaq.Accounts.Person.t()} | {:error, term()}
  def resolve(%Incoming{provider: provider}, _opts) when provider in [:web, "web"],
    do: {:error, :bo_user}

  def resolve(%Incoming{author_id: nil}, _opts), do: {:error, :no_author}

  def resolve(%Incoming{} = incoming, opts) do
    provider = to_string(incoming.provider)

    platform =
      incoming.routing_context.identity_platform ||
        to_string(Bridge.provider_to_bridge_key(provider) || provider)

    with :ok <- validate_connector(incoming.routing_context, provider) do
      resolve_author(incoming, platform, opts)
    end
  end

  @doc "Discovers this message's visible recipients through the same identity owner as authors."
  @spec resolve_audience(Incoming.t(), pos_integer()) ::
          {:ok, [pos_integer()]} | {:error, :connector_mismatch | :invalid_recipient_evidence}
  def resolve_audience(
        %Incoming{
          provider: provider,
          author_id: author_id,
          routing_context: %RoutingContext{
            channel_config_id: config_id,
            audience: %Audience{} = audience
          }
        },
        config_id
      )
      when is_integer(config_id) and config_id > 0 do
    with :ok <-
           validate_connector(
             %RoutingContext{channel_config_id: config_id},
             to_string(provider),
             true
           ),
         %Audience{sender: ^author_id} <- Audience.normalize(audience) do
      audience.recipients
      |> Enum.map(fn identifier ->
        attrs =
          Resolver.normalize(audience.platform, %{
            channel_id: identifier,
            display_name: participant_name(audience, identifier)
          })

        People.find_or_create_from_channel(
          audience.platform,
          Map.put(attrs, "channel_config_id", config_id)
        )
      end)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, %{id: id, status: "active"}}, {:ok, ids} -> {:cont, {:ok, [id | ids]}}
        {:ok, _inactive}, acc -> {:cont, acc}
        {:error, reason}, _ -> {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, ids} -> {:ok, ids |> Enum.uniq() |> Enum.sort()}
        error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_recipient_evidence}
    end
  end

  def resolve_audience(
        %Incoming{routing_context: %RoutingContext{channel_config_id: id}},
        id
      )
      when is_integer(id) and id > 0,
      do: {:error, :invalid_recipient_evidence}

  def resolve_audience(%Incoming{}, _config_id),
    do: {:error, :connector_mismatch}

  def resolve_audience(_, _), do: {:error, :invalid_recipient_evidence}

  defp participant_name(audience, identifier) do
    Enum.find_value(audience.participants, fn participant ->
      if participant.identifier == identifier, do: participant.display_name
    end)
  end

  defp validate_connector(context, platform, require_enabled \\ false)

  defp validate_connector(context, platform, require_enabled) do
    with {:ok, _config} <- fetch_connector(context, platform, require_enabled), do: :ok
  end

  defp fetch_connector(%{channel_config_id: id}, platform, require_enabled)
       when is_integer(id) and id > 0 do
    case Repo.get(ChannelConfig, id) do
      %ChannelConfig{provider: provider, kind: "retrieval", enabled: enabled, archived_at: nil} =
          config
      when (is_nil(platform) or provider == platform) and (not require_enabled or enabled) ->
        {:ok, config}

      _ ->
        {:error, :connector_mismatch}
    end
  end

  defp fetch_connector(_, _platform, _require_enabled), do: {:error, :connector_mismatch}

  defp resolve_author(incoming, platform, opts) do
    config_id = incoming.routing_context.channel_config_id
    raw_dm_channel_id = if incoming.is_dm, do: incoming.channel_id, else: nil

    canonical =
      Resolver.normalize(platform, %{
        channel_id: incoming.author_id,
        username: incoming.author_name,
        display_name: incoming.author_name,
        dm_channel_id: raw_dm_channel_id,
        metadata: incoming.metadata
      })

    channel_id = canonical["channel_id"] || ""

    case match_author(platform, channel_id, config_id) do
      {:ok, %{incomplete: false} = person} ->
        channel = find_channel(person, platform, channel_id, config_id)
        touch_channel(channel, canonical["dm_channel_id"])
        maybe_backfill_dm_channel(channel, platform, incoming, opts)
        {:ok, person}

      {:error, :identity_scope_changed} = error ->
        error

      _ ->
        enriched = maybe_enrich(platform, incoming.author_id, canonical, config_id, opts)
        slow_path(platform, enriched, channel_id, config_id, incoming, opts)
    end
  end

  defp match_author(platform, channel_id, config_id),
    do: People.match_by_channel(platform, channel_id, config_id)

  @spec person_payload(map()) :: person_payload()
  def person_payload(person) when is_map(person) do
    %{
      id: Map.get(person, :id) || Map.get(person, "id"),
      full_name: Map.get(person, :full_name) || Map.get(person, "full_name"),
      team_ids: Map.get(person, :team_ids) || Map.get(person, "team_ids") || []
    }
  end

  defp slow_path(platform, enriched, fallback_channel_id, config_id, incoming, opts) do
    case discover_person(platform, enriched, config_id) do
      {:ok, person} ->
        channel =
          find_channel(person, platform, enriched["channel_id"] || fallback_channel_id, config_id)

        if channel, do: People.record_interaction(channel)
        maybe_backfill_dm_channel(channel, platform, incoming, opts)
        {:ok, person}

      err ->
        err
    end
  end

  defp discover_person(_platform, {:error, _} = error, _config_id), do: error

  defp discover_person(platform, profile, config_id) do
    attrs = if config_id, do: Map.put(profile, "channel_config_id", config_id), else: profile
    People.find_or_create_from_channel(platform, attrs)
  end

  defp maybe_enrich(platform, author_id, canonical, config_id, opts) do
    channels_mod =
      Keyword.get(
        opts,
        :channels_router,
        Application.get_env(:zaq, :identity_plug_channels_router, Zaq.Channels.Api)
      )

    result =
      if channels_mod == Zaq.Channels.Api do
        event_opts =
          if is_nil(Keyword.get(opts, :profile_context)),
            do: [action: :fetch_profile],
            else: [action: :fetch_profile, confidential: true]

        event =
          Zaq.Event.new(
            %{
              provider: platform,
              author_id: author_id,
              channel_config_id: config_id,
              profile_context: Keyword.get(opts, :profile_context)
            },
            :channels,
            opts: event_opts
          )

        NodeRouter.dispatch(event).response
      else
        event =
          Zaq.Event.new(
            %{module: channels_mod, function: :fetch_profile, args: [platform, author_id]},
            :channels,
            opts: [action: :invoke]
          )

        NodeRouter.dispatch(event).response
      end

    case result do
      {:ok, profile} -> Map.merge(canonical, stringify_profile(profile))
      {:error, :invalid_profile} = error -> error
      _ -> canonical
    end
  end

  defp touch_channel(nil, _dm_channel_id), do: :ok

  defp touch_channel(channel, dm_channel_id)
       when is_binary(dm_channel_id) and not is_nil(dm_channel_id) do
    if is_nil(channel.dm_channel_id),
      do: People.update_channel(channel, %{dm_channel_id: dm_channel_id}),
      else: People.record_interaction(channel)
  end

  defp touch_channel(channel, _dm_channel_id), do: People.record_interaction(channel)

  defp maybe_backfill_dm_channel(nil, _platform, _incoming, _opts), do: :ok
  defp maybe_backfill_dm_channel(_channel, _platform, %{is_dm: true}, _opts), do: :ok

  defp maybe_backfill_dm_channel(%{dm_channel_id: id}, _platform, _incoming, _opts)
       when is_binary(id) and id != "",
       do: :ok

  defp maybe_backfill_dm_channel(channel, platform, incoming, opts) do
    channels_mod =
      Keyword.get(
        opts,
        :channels_router,
        Application.get_env(:zaq, :identity_plug_channels_router, Zaq.Channels.Api)
      )

    result =
      if channels_mod == Zaq.Channels.Api do
        event =
          Zaq.Event.new(
            %{
              provider: platform,
              author_id: incoming.author_id,
              channel_config_id: incoming.routing_context.channel_config_id
            },
            :channels,
            opts: [action: :open_dm_channel]
          )

        NodeRouter.dispatch(event).response
      else
        event =
          Zaq.Event.new(
            %{
              module: channels_mod,
              function: :open_dm_channel,
              args: [platform, incoming.author_id]
            },
            :channels,
            opts: [action: :invoke]
          )

        NodeRouter.dispatch(event).response
      end

    case result do
      {:ok, dm_channel_id} -> People.update_channel(channel, %{dm_channel_id: dm_channel_id})
      _ -> :ok
    end
  end

  defp find_channel(person, platform, channel_id, config_id)
       when is_binary(channel_id) and channel_id != "" do
    channel_id = PersonChannel.normalize_identifier(platform, channel_id)

    Enum.find(person.channels || [], fn c ->
      c.platform == platform and c.channel_identifier == channel_id and
        c.channel_config_id == config_id
    end)
  end

  defp find_channel(_person, _platform, _channel_id, _config_id), do: nil

  defp stringify_profile(profile) do
    Map.new(profile, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
