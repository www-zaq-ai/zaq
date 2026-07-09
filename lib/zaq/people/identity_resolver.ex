defmodule Zaq.People.IdentityResolver do
  @moduledoc """
  Resolves a channel message author to a minimal ZAQ Person identity.

  Channel ingress uses this before dispatching an agent event so downstream
  consumers receive a stable, JSON-safe actor shape:

      %{person: %{id: id, full_name: full_name, team_ids: team_ids}}

  On any error, callers should keep the message unresolved.
  """

  alias Zaq.Accounts.People
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.NodeRouter
  alias Zaq.People.Resolver

  @type person_payload :: %{id: integer(), full_name: String.t() | nil, team_ids: [integer()]}

  @spec resolve(Incoming.t(), keyword()) :: {:ok, Zaq.Accounts.Person.t()} | {:error, term()}
  def resolve(%Incoming{provider: provider}, _opts) when provider in [:web, "web"],
    do: {:error, :bo_user}

  def resolve(%Incoming{author_id: nil}, _opts), do: {:error, :no_author}

  def resolve(%Incoming{} = incoming, opts) do
    platform = incoming.provider |> to_string() |> canonical_platform()

    raw_dm_channel_id = if incoming.is_dm, do: incoming.channel_id, else: nil

    canonical =
      Resolver.normalize(platform, %{
        channel_id: incoming.author_id,
        username: incoming.author_name,
        dm_channel_id: raw_dm_channel_id,
        metadata: incoming.metadata
      })

    channel_id = canonical["channel_id"] || ""

    case People.match_by_channel(platform, channel_id) do
      {:ok, %{incomplete: false} = person} ->
        channel = find_channel(person, platform, channel_id)
        touch_channel(channel, canonical["dm_channel_id"])
        maybe_backfill_dm_channel(channel, platform, incoming, opts)
        {:ok, person}

      _ ->
        enriched = maybe_enrich(platform, incoming.author_id, canonical, opts)
        slow_path(platform, enriched, channel_id, incoming, opts)
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

  defp slow_path(platform, enriched, fallback_channel_id, incoming, opts) do
    case People.find_or_create_from_channel(platform, enriched) do
      {:ok, person} ->
        channel = find_channel(person, platform, enriched["channel_id"] || fallback_channel_id)
        if channel, do: People.record_interaction(channel)
        maybe_backfill_dm_channel(channel, platform, incoming, opts)
        {:ok, person}

      err ->
        err
    end
  end

  defp maybe_enrich(platform, author_id, canonical, opts) do
    channels_mod =
      Keyword.get(
        opts,
        :channels_router,
        Application.get_env(:zaq, :identity_plug_channels_router, Zaq.Channels.Api)
      )

    result =
      if channels_mod == Zaq.Channels.Api do
        event =
          Zaq.Event.new(%{provider: platform, author_id: author_id}, :channels,
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
          Zaq.Event.new(%{provider: platform, author_id: incoming.author_id}, :channels,
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

  defp find_channel(person, platform, channel_id)
       when is_binary(channel_id) and channel_id != "" do
    Enum.find(person.channels || [], fn c ->
      c.platform == platform and c.channel_identifier == channel_id
    end)
  end

  defp find_channel(_person, _platform, _channel_id), do: nil

  defp canonical_platform("email:imap"), do: "email"
  defp canonical_platform(platform), do: platform

  defp stringify_profile(profile) do
    Map.new(profile, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
