defmodule Zaq.Channels.EmailBridge.ImapAdapter.Threading do
  @moduledoc """
  Resolves email threading identifiers from parsed headers.

  - `resolve_thread_key/1` returns the root key used for conversation grouping.
  - `resolve_thread_id/1` returns the closest parent/current thread id used for
    reply continuity metadata.

  Header parsing assumes RFC-style linear whitespace between message ids.
  """

  alias Zaq.Utils.EmailUtils

  @spec resolve_thread_id(map()) :: String.t() | nil
  def resolve_thread_id(headers) when is_map(headers) do
    in_reply_to =
      EmailUtils.normalize_message_id(
        Map.get(headers, "in_reply_to") || Map.get(headers, :in_reply_to)
      )

    references =
      Map.get(headers, "references") ||
        Map.get(headers, :references) ||
        Map.get(headers, "references_header") ||
        Map.get(headers, :references_header)

    message_id =
      EmailUtils.normalize_message_id(
        Map.get(headers, "message_id") || Map.get(headers, :message_id)
      )

    in_reply_to || last_reference(references) || message_id
  end

  def resolve_thread_id(_), do: nil

  @spec resolve_thread_key(map()) :: String.t() | nil
  def resolve_thread_key(headers) when is_map(headers) do
    references =
      Map.get(headers, "references") ||
        Map.get(headers, :references) ||
        Map.get(headers, "references_header") ||
        Map.get(headers, :references_header)

    in_reply_to =
      EmailUtils.normalize_message_id(
        Map.get(headers, "in_reply_to") || Map.get(headers, :in_reply_to)
      )

    message_id =
      EmailUtils.normalize_message_id(
        Map.get(headers, "message_id") || Map.get(headers, :message_id)
      )

    first_reference(references) || in_reply_to || message_id
  end

  def resolve_thread_key(_), do: nil

  defp last_reference(nil), do: nil

  defp last_reference(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&EmailUtils.normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp last_reference(value) when is_binary(value) do
    value
    |> String.split(~r/[ \t]+/, trim: true)
    |> Enum.map(&EmailUtils.normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp last_reference(_), do: nil

  defp first_reference(nil), do: nil

  defp first_reference(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&EmailUtils.normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  defp first_reference(value) when is_binary(value) do
    value
    |> String.split(~r/[ \t]+/, trim: true)
    |> Enum.map(&EmailUtils.normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  defp first_reference(_), do: nil
end
