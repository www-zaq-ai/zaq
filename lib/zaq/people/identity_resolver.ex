defmodule Zaq.People.IdentityResolver do
  @moduledoc """
  Resolves a channel message author to a minimal ZAQ Person identity.

  Channel ingress uses this before dispatching an agent event so downstream
  consumers receive a stable, JSON-safe actor shape:

      %{person: %{id: id, full_name: full_name, team_ids: team_ids}}

  On any error, callers should keep the message unresolved.
  """

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.NodeRouter
  alias Zaq.People.Resolver
  alias Zaq.Repo

  @type person_payload :: %{id: integer(), full_name: String.t() | nil, team_ids: [integer()]}

  @spec resolve(Incoming.t(), keyword()) :: {:ok, Zaq.Accounts.Person.t()} | {:error, term()}
  def resolve(%Incoming{provider: provider}, _opts) when provider in [:web, "web"],
    do: {:error, :bo_user}

  def resolve(%Incoming{author_id: nil}, _opts), do: {:error, :no_author}

  def resolve(%Incoming{} = incoming, opts) do
    platform = incoming.provider |> to_string() |> canonical_platform()

    with :ok <- validate_connector(incoming.routing_context, platform) do
      resolve_author(incoming, platform, opts)
    end
  end

  defp validate_connector(%RoutingContext{channel_config_id: nil}, _platform), do: :ok

  defp validate_connector(%RoutingContext{channel_config_id: id}, platform)
       when is_integer(id) and id > 0 do
    case Repo.get(ChannelConfig, id) do
      %ChannelConfig{provider: "email:imap", kind: "retrieval", archived_at: nil}
      when platform == "email" ->
        :ok

      %ChannelConfig{provider: ^platform, kind: "retrieval", archived_at: nil} ->
        :ok

      _ ->
        {:error, :connector_mismatch}
    end
  end

  defp validate_connector(_, _platform), do: {:error, :connector_mismatch}

  defp resolve_author(incoming, platform, opts) do
    config_id = incoming.routing_context.channel_config_id
    raw_dm_channel_id = if incoming.is_dm, do: incoming.channel_id, else: nil

    canonical =
      Resolver.normalize(platform, %{
        channel_id: incoming.author_id,
        username: incoming.author_name,
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

      _ ->
        enriched = maybe_enrich(platform, incoming.author_id, canonical, config_id, opts)
        slow_path(platform, enriched, channel_id, config_id, incoming, opts)
    end
  end

  defp match_author(platform, channel_id, nil), do: People.match_by_channel(platform, channel_id)

  defp match_author(platform, channel_id, config_id) do
    case People.match_by_channel(platform, channel_id, config_id) do
      {:error, :not_found} when platform != "email" ->
        People.link_legacy_channel_to_connector(platform, channel_id, config_id)
        People.match_by_channel(platform, channel_id, config_id)

      match ->
        match
    end
  end

  @spec person_payload(map()) :: person_payload()
  def person_payload(person) when is_map(person) do
    %{
      id: Map.get(person, :id) || Map.get(person, "id"),
      full_name: Map.get(person, :full_name) || Map.get(person, "full_name"),
      team_ids: Map.get(person, :team_ids) || Map.get(person, "team_ids") || []
    }
  end

  defp slow_path(platform, enriched, fallback_channel_id, config_id, incoming, opts) do
    attrs = if config_id, do: Map.put(enriched, "channel_config_id", config_id), else: enriched

    case People.find_or_create_from_channel(platform, attrs) do
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

  defp maybe_enrich(platform, author_id, canonical, config_id, opts) do
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
            %{provider: platform, author_id: author_id, channel_config_id: config_id},
            :channels,
            opts: [action: :fetch_profile]
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

  defp canonical_platform("email:imap"), do: "email"
  defp canonical_platform(platform), do: platform

  defp stringify_profile(profile) do
    Map.new(profile, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
