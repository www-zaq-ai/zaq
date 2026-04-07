defmodule Zaq.Channels.EmailBridge.ImapAdapter.Threading do
  @moduledoc false

  @spec resolve_thread_id(map()) :: String.t() | nil
  def resolve_thread_id(headers) when is_map(headers) do
    in_reply_to =
      normalize_message_id(Map.get(headers, "in_reply_to") || Map.get(headers, :in_reply_to))

    references =
      Map.get(headers, "references") ||
        Map.get(headers, :references) ||
        Map.get(headers, "references_header") ||
        Map.get(headers, :references_header)

    message_id =
      normalize_message_id(Map.get(headers, "message_id") || Map.get(headers, :message_id))

    in_reply_to || last_reference(references) || message_id
  end

  def resolve_thread_id(_), do: nil

  defp last_reference(nil), do: nil

  defp last_reference(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp last_reference(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp last_reference(_), do: nil

  defp normalize_message_id(nil), do: nil

  defp normalize_message_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp normalize_message_id(_), do: nil
end
