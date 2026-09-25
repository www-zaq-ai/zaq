defmodule ZaqWeb.History.ConversationContext do
  @moduledoc """
  Human-readable connector, channel and thread identifiers from conversation data.

  Legacy and People projections may lack these optional fields. Provider IDs are
  display-only and must be rendered as escaped text, never fabricated links.
  """

  @doc "Returns the available display labels for a channel-scoped conversation."
  @spec labels(map()) :: [String.t()]
  def labels(conversation) when is_map(conversation) do
    config_id = Map.get(conversation, :channel_config_id)
    channel_id = Map.get(conversation, :external_channel_id)
    thread_id = Map.get(conversation, :external_thread_id)

    if present?(config_id) or present?(channel_id) or present?(thread_id) do
      []
      |> maybe_add(present?(config_id), "Connection ##{config_id}")
      |> maybe_add(present?(channel_id), "Channel: #{channel_id}")
      |> maybe_add(not present?(channel_id), "Channel unavailable")
      |> maybe_add(present?(thread_id), "Thread: #{thread_id}")
      |> maybe_add(present?(channel_id) and not present?(thread_id), "Channel-level")
    else
      []
    end
  end

  defp maybe_add(labels, true, label), do: labels ++ [label]
  defp maybe_add(labels, false, _label), do: labels

  defp present?(id) when is_binary(id), do: String.trim(id) != ""
  defp present?(id) when is_integer(id), do: id > 0
  defp present?(_id), do: false
end
