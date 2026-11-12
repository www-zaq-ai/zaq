defmodule Zaq.Engine.ChannelHistoryUpdates do
  @moduledoc """
  Best-effort, identifier-only invalidations for the BO transcript display.

  Verified outer domain operations call this after commit. Nested writes do not
  publish: their outer owner must publish its changed references. No business
  write or recovery depends on notification success or a connected browser.
  """

  import Ecto.Query
  require Logger

  alias Zaq.Engine.Conversations.{Message, TranscriptMessage}
  alias Zaq.Event
  alias Zaq.Repo

  @doc "Names the display topic; knowing a topic is not authorization to read its data."
  def topic(transcript_id), do: "bo:channel_history:#{transcript_id}"

  @doc "Keeps an owning operation's result unchanged while optionally invalidating its UI rows."
  def publish_result(result, ids, opts \\ []) do
    if match?({:ok, _}, result), do: publish(ids, opts)
    result
  end

  @doc "Notifies affected origins and confirmed targets after the caller's outer commit."
  def publish(ids, opts \\ []) do
    publish_scopes(fn -> affected_scopes(ids) end, opts)
  end

  @doc "Notifies from already-loaded committed messages without reloading their metadata."
  def publish_messages(messages, opts \\ []) do
    publish_scopes(fn -> scopes_for_messages(messages) end, opts)
  end

  defp publish_scopes(resolve_scopes, opts) do
    unless Repo.in_transaction?() do
      resolve_scopes.() |> broadcast(opts)
    end

    :ok
  rescue
    _ ->
      Logger.warning("[ChannelHistoryUpdates] UI invalidation unavailable")
      :ok
  catch
    _kind, _ ->
      Logger.warning("[ChannelHistoryUpdates] UI invalidation unavailable")
      :ok
  end

  @doc "Resolves committed placements and fixed confirmation targets without granting membership."
  def affected_scopes(ids) do
    ids =
      Enum.flat_map(ids, fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          _ -> []
        end
      end)

    from(m in Message,
      where:
        m.id in ^ids or
          fragment("?->>'in_reply_to_message_id' = ANY(?::text[])", m.metadata, ^ids),
      select: %{id: m.id, metadata: m.metadata}
    )
    |> Repo.all()
    |> scopes_for_messages()
  end

  defp scopes_for_messages(messages) do
    origins =
      Enum.flat_map(messages, fn message ->
        [message.id, message.metadata["in_reply_to_message_id"]]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    placements =
      Repo.all(
        from p in TranscriptMessage,
          where: p.message_id in ^origins,
          select: {p.message_id, p.transcript_id}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.reduce(messages, %{}, fn message, scopes ->
      targets = get_in(message.metadata, ["history_association", "transcript_ids"]) || []

      related =
        Map.get(placements, message.id, []) ++
          Map.get(placements, message.metadata["in_reply_to_message_id"], []) ++ targets

      Enum.reduce(Enum.uniq(related), scopes, fn id, acc ->
        Map.update(acc, id, [message.id], &Enum.uniq([message.id | &1]))
      end)
    end)
  end

  defp broadcast(scopes, opts) do
    router = Keyword.get(opts, :history_updates_node_router, Zaq.NodeRouter)

    Enum.each(scopes, fn {id, message_ids} ->
      Event.new({:broadcast, topic(id), {:channel_history_updated, id, message_ids}}, :channels,
        type: :async,
        opts: [action: :broadcast, confidential: true]
      )
      |> router.dispatch()
    end)
  end
end
