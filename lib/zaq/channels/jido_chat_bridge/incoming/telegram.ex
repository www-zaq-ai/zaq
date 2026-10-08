defmodule Zaq.Channels.JidoChatBridge.Incoming.Telegram do
  @moduledoc "Normalizes Telegram conversations, timestamps and chat-local message namespaces."

  @behaviour Zaq.Channels.IncomingNormalization

  alias Zaq.Channels.{IncomingNormalization, MessageTimestamp}
  alias Zaq.Engine.Messages.ConversationIdentity

  @impl true
  def normalize(%{chat_type: type, is_dm: is_dm, external_room_id: room}, raw, timestamp)
      when is_map(raw) do
    with chat when is_map(chat) <- Map.get(raw, :chat) || Map.get(raw, "chat"),
         true <- IncomingNormalization.same_room?(value(chat, :id), room),
         {:ok, kind} <- conversation_type(value(chat, :type), type, is_dm),
         scope when is_binary(scope) <- ConversationIdentity.normalize(room) do
      {:ok,
       %{
         conversation_type: kind,
         source_scope: scope,
         sender_id: sender_id(raw),
         provider_sent_at: MessageTimestamp.normalize(value(raw, :date) || timestamp, :second)
       }}
    else
      _ -> {:error, :unverified_communication_facts}
    end
  end

  def normalize(_, _, _), do: {:error, :unverified_communication_facts}

  @impl true
  def source_scope(room), do: ConversationIdentity.normalize(room)

  defp conversation_type("private", :private, true), do: {:ok, :one_to_one}
  defp conversation_type("group", :group, false), do: {:ok, :room}
  defp conversation_type("supergroup", :supergroup, false), do: {:ok, :room}
  defp conversation_type("channel", :channel, false), do: {:ok, :room}
  defp conversation_type(_, _, _), do: {:error, :unverified_communication_facts}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp sender_id(raw) do
    case value(raw, :from) do
      sender when is_map(sender) -> ConversationIdentity.normalize(value(sender, :id))
      _ -> nil
    end
  end
end
