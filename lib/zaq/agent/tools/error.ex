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

  # An Ecto.Changeset is a struct but not an Exception, so it must be caught
  # before the generic `%_{}` clause below — otherwise `Exception.message/1`
  # raises and it falls through to a raw `#Ecto.Changeset<...>` dump. Field
  # errors are rendered as prose (e.g. "channel_identifier can't be blank").
  #
  # The minimal traversal is replicated here on purpose: core code (`lib/zaq/`)
  # must not depend on the web layer's `ZaqWeb.ChangesetErrors`.
  defp to_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

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
