defmodule Zaq.Agent.Tools.Error do
  @moduledoc """
  Shared formatter for agent-visible tool errors.

  Sanitizes sensitive values and bounds message size before returning text
  intended for LLM context.
  """

  alias Jido.AI.Observe

  @max_chars 300

  @spec format(term()) :: String.t()
  def format(reason) do
    reason
    |> sanitize_reason()
    |> to_message()
    |> String.trim()
    |> truncate(@max_chars)
  end

  defp sanitize_reason(reason) do
    Observe.sanitize_sensitive(reason)
  rescue
    _ -> reason
  end

  defp to_message(%{display_message: message}) when is_binary(message), do: message
  defp to_message(%{"display_message" => message}) when is_binary(message), do: message
  defp to_message(%{message: message}) when is_binary(message), do: message
  defp to_message(%{"message" => message}) when is_binary(message), do: message

  defp to_message(%_{} = exception) do
    Exception.message(exception)
  rescue
    _ -> inspect(exception, limit: 20, printable_limit: 500)
  end

  defp to_message(reason) when is_binary(reason), do: reason
  defp to_message(reason) when is_atom(reason), do: inspect(reason)
  defp to_message(reason), do: inspect(reason, limit: 20, printable_limit: 500)

  defp truncate(message, max_chars) when byte_size(message) <= max_chars, do: message
  defp truncate(message, max_chars), do: binary_part(message, 0, max_chars) <> "..."
end
