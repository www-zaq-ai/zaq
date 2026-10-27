defmodule Zaq.Channels.JidoChatBridge.Incoming.WhatsApp do
  @moduledoc "Normalizes evidenced WhatsApp room, sender and mention facts from the linked device."

  @behaviour Zaq.Channels.IncomingNormalization

  alias Zaq.Channels.{IncomingNormalization, MessageTimestamp}
  alias Zaq.Engine.Messages.ConversationIdentity

  @impl true
  def normalize(%{chat_type: type, is_dm: dm, external_room_id: room}, raw, timestamp)
      when is_map(raw) and is_binary(room) do
    with true <- IncomingNormalization.same_room?(value(raw, :channel_jid), room),
         {:ok, kind} <- kind(room, type, dm) do
      {:ok,
       %{
         conversation_type: kind,
         source_scope: source_scope(room),
         sender_id: value(raw, :from_jid),
         provider_sent_at:
           MessageTimestamp.normalize(value(raw, :timestamp) || timestamp, :second)
       }}
    else
      _ -> {:error, :unverified_communication_facts}
    end
  end

  def normalize(_, _, _), do: {:error, :unverified_communication_facts}

  @impl true
  def source_scope(room), do: ConversationIdentity.normalize(room)

  defp kind(room, :group, false) do
    if String.ends_with?(room, "@g.us"), do: {:ok, :room}, else: {:error, :unknown_room}
  end

  defp kind(room, :dm, true) do
    if String.ends_with?(room, ["@s.whatsapp.net", "@lid"]),
      do: {:ok, :one_to_one},
      else: {:error, :unknown_room}
  end

  defp kind(_, _, _), do: {:error, :unknown_room}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
