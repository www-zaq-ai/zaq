defmodule Zaq.Channels.JidoChatBridge.Incoming.Mattermost do
  @moduledoc "Normalizes Mattermost conversation and message identity facts."

  @behaviour Zaq.Channels.IncomingNormalization

  alias Zaq.Channels.{IncomingNormalization, MessageTimestamp}

  @doc "Returns supported room query capabilities."
  defdelegate room_capabilities(config, channel_id), to: Zaq.Channels.MattermostAdmin

  @doc "Returns a complete, normalized room-member snapshot."
  defdelegate room_members(config, channel_id), to: Zaq.Channels.MattermostAdmin

  @doc "Reads an exact room message through the provider transport."
  defdelegate fetch_room_message(config, channel_id, message_id), to: Zaq.Channels.MattermostAdmin

  @impl true
  def normalize(%{chat_type: type, is_dm: is_dm, external_room_id: room}, raw, timestamp)
      when is_map(raw) do
    post = Map.get(raw, "post") || raw

    with true <- is_map(post),
         true <- IncomingNormalization.same_room?(Map.get(post, "channel_id"), room),
         {:ok, kind} <- conversation_type(Map.get(raw, "channel_type"), type, is_dm) do
      {:ok,
       %{
         conversation_type: kind,
         source_scope: nil,
         sender_id: Map.get(post, "user_id"),
         provider_sent_at:
           MessageTimestamp.normalize(timestamp || Map.get(post, "create_at"), :millisecond)
       }}
    else
      _ -> {:error, :unverified_communication_facts}
    end
  end

  def normalize(_, _, _), do: {:error, :unverified_communication_facts}

  @impl true
  def source_scope(_room), do: nil

  defp conversation_type("D", :dm, true), do: {:ok, :one_to_one}
  defp conversation_type(type, :public, false) when type in ["O", "P"], do: {:ok, :room}
  defp conversation_type(type, :private, false) when type in ["O", "P"], do: {:ok, :room}
  defp conversation_type(_, _, _), do: {:error, :unverified_communication_facts}
end
