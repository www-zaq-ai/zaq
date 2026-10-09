defmodule Zaq.Channels.JidoChatBridge.Incoming.Discord do
  @moduledoc "Normalizes independently verified Discord guild, thread and direct conversations."

  @behaviour Zaq.Channels.IncomingNormalization

  alias Zaq.Channels.{IncomingNormalization, MessageTimestamp}

  @doc "Enriches direct conversations with independently fetched channel metadata."
  def enrich(%Jido.Chat.Incoming{channel_meta: %{is_dm: true}} = incoming, adapter) do
    with {:error, _} <- normalize(incoming.channel_meta, incoming.raw || %{}, incoming.timestamp),
         true <- function_exported?(adapter, :fetch_metadata, 2),
         {:ok, %{id: room, is_dm: true, metadata: metadata}} <-
           adapter.fetch_metadata(incoming.external_room_id, []),
         true <- room == incoming.external_room_id and is_map(metadata) do
      %{incoming | raw: Map.put(incoming.raw || %{}, "channel", metadata)}
    else
      _ -> incoming
    end
  rescue
    _ -> incoming
  end

  def enrich(incoming, _adapter), do: incoming

  @impl true
  def normalize(%{chat_type: type, is_dm: false, external_room_id: room}, raw, timestamp)
      when type in [:guild, :thread] and is_map(raw) do
    guild_id = value(raw, :guild_id)
    room_id = if(type == :thread, do: value(raw, :parent_id), else: value(raw, :channel_id))

    if IncomingNormalization.identifier?(guild_id) and
         IncomingNormalization.same_room?(room_id, room) do
      {:ok, result(:room, timestamp)}
    else
      {:error, :unverified_communication_facts}
    end
  end

  def normalize(%{chat_type: :dm, is_dm: true, external_room_id: room}, raw, timestamp)
      when is_map(raw) do
    with channel when is_map(channel) <- value(raw, :channel),
         1 <- value(channel, :type),
         true <- IncomingNormalization.same_room?(value(channel, :id), room),
         true <- IncomingNormalization.same_room?(value(raw, :channel_id), room),
         nil <- value(raw, :guild_id) do
      {:ok, result(:one_to_one, timestamp)}
    else
      _ -> {:error, :unverified_communication_facts}
    end
  end

  def normalize(_, _, _), do: {:error, :unverified_communication_facts}

  @impl true
  def source_scope(_room), do: nil

  defp result(kind, timestamp) do
    %{
      conversation_type: kind,
      source_scope: nil,
      provider_sent_at: MessageTimestamp.normalize(timestamp, :iso8601)
    }
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
