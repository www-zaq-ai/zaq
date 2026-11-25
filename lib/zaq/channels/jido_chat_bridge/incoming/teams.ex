defmodule Zaq.Channels.JidoChatBridge.Incoming.Teams do
  @moduledoc """
  Normalizes Microsoft Teams conversations, senders and chat-local message namespaces.
  """

  @behaviour Zaq.Channels.IncomingNormalization

  alias Zaq.Channels.{IncomingNormalization, MessageTimestamp}
  alias Zaq.Engine.Messages.ConversationIdentity

  @impl true
  def normalize(%{chat_type: type, is_dm: is_dm, external_room_id: room}, raw, timestamp)
      when is_map(raw) do
    with conversation when is_map(conversation) <- value(raw, :conversation),
         {:ok, kind} <- conversation_type(value(conversation, :conversationType), type, is_dm),
         true <- IncomingNormalization.same_room?(activity_room(raw, conversation, type), room),
         scope when is_binary(scope) <- source_scope(room) do
      {:ok,
       %{
         conversation_type: kind,
         source_scope: scope,
         sender_id: sender_id(raw),
         provider_sent_at:
           MessageTimestamp.normalize(timestamp || value(raw, :timestamp), :iso8601)
       }}
    else
      _ -> {:error, :unverified_communication_facts}
    end
  end

  def normalize(_, _, _), do: {:error, :unverified_communication_facts}

  @impl true
  def source_scope(room), do: ConversationIdentity.normalize(room)

  defp conversation_type("personal", :private, true), do: {:ok, :one_to_one}
  defp conversation_type("groupChat", :group, false), do: {:ok, :room}
  defp conversation_type("channel", :channel, false), do: {:ok, :room}
  defp conversation_type(_, _, _), do: {:error, :unverified_communication_facts}

  defp activity_room(raw, _conversation, :channel), do: raw |> value(:channelData) |> channel_id()
  defp activity_room(_raw, conversation, _type), do: value(conversation, :id)

  defp channel_id(%{} = channel_data) do
    case value(channel_data, :channel) do
      %{} = channel -> value(channel, :id)
      _ -> nil
    end
  end

  defp channel_id(_channel_data), do: nil

  defp sender_id(raw) do
    case value(raw, :from) do
      %{} = sender -> value(sender, :aadObjectId) || value(sender, :id)
      _ -> nil
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
