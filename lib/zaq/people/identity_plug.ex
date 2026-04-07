defmodule Zaq.People.IdentityPlug do
  @moduledoc """
  Pipeline plug that resolves a channel message author to a Person record.

  Called at the start of `Zaq.Agent.Pipeline.run/2`. Enriches the incoming
  message with `person_id` from the People directory.

  Fast path: person already known and complete → record interaction, skip enrichment.
  Slow path: no match or incomplete → fetch profile via Channels.Router, then
  find_or_create.

  On any error, returns the message unchanged (person_id remains nil).
  """

  alias Zaq.Accounts.People
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.NodeRouter
  alias Zaq.People.Resolver

  @spec call(Incoming.t(), keyword()) :: Incoming.t()
  def call(%Incoming{} = incoming, opts) do
    case resolve(incoming, opts) do
      {:ok, person} -> %{incoming | person_id: person.id}
      {:error, _} -> incoming
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve(%Incoming{author_id: nil}, _opts), do: {:error, :no_author}

  defp resolve(%Incoming{} = incoming, opts) do
    platform = to_string(incoming.provider)

    canonical =
      Resolver.normalize(platform, %{
        channel_id: incoming.author_id,
        username: incoming.author_name,
        dm_channel_id: incoming.channel_id,
        metadata: incoming.metadata
      })

    channel_id = canonical["channel_id"] || ""

    case People.match_by_channel(platform, channel_id) do
      {:ok, %{incomplete: false} = person} ->
        # Fast path: known complete person — record interaction and backfill dm_channel_id if missing
        channel = find_channel(person, platform, channel_id)
        touch_channel(channel, canonical["dm_channel_id"])
        {:ok, person}

      _ ->
        enriched = maybe_enrich(platform, incoming.author_id, canonical, opts)
        slow_path(platform, enriched, channel_id)
    end
  end

  defp slow_path(platform, enriched, fallback_channel_id) do
    case People.find_or_create_from_channel(platform, enriched) do
      {:ok, person} ->
        channel = find_channel(person, platform, enriched["channel_id"] || fallback_channel_id)
        if channel, do: People.record_interaction(channel)
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
        Application.get_env(:zaq, :identity_plug_channels_router, Zaq.Channels.Router)
      )

    case NodeRouter.call(:channels, channels_mod, :fetch_profile, [platform, author_id]) do
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

  defp find_channel(person, platform, channel_id)
       when is_binary(channel_id) and channel_id != "" do
    Enum.find(person.channels || [], fn c ->
      c.platform == platform and c.channel_identifier == channel_id
    end)
  end

  defp find_channel(_person, _platform, _channel_id), do: nil

  defp stringify_profile(profile) do
    Map.new(profile, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
