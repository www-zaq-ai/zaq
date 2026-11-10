defmodule Zaq.Agent.Tools.Error do
  @moduledoc """
  Shared formatter for agent-visible tool errors.

  Sanitizes sensitive values and bounds message size before returning text
  intended for LLM context.
  """

  alias Jido.Action.Error, as: ActionError
  alias Jido.AI.Observe

  @max_chars 300

  @trace_errors [
    ActionError.InvalidInputError,
    ActionError.ExecutionFailureError,
    ActionError.TimeoutError,
    ActionError.ConfigurationError,
    ActionError.InternalError
  ]

  @doc """
  Projects known Action errors into bounded trace evidence, excluding details.

  Unknown structs retain only their type; no arbitrary exception formatter or
  inspect fallback is invoked on runtime objects or their captured values.
  """
  @spec trace_summary(struct()) :: map()
  def trace_summary(%module{message: message})
      when module in @trace_errors and is_binary(message) do
    %{type: Atom.to_string(module), message: trace_message(message)}
  end

  def trace_summary(%module{}), do: %{type: Atom.to_string(module)}

  defp trace_message(message) do
    formatted = format(%{message: Observe.sanitize_transport_payload(message)})

    # The public formatter bounds bytes; do not retain a split codepoint in JSON.
    case :unicode.characters_to_binary(formatted) do
      {:error, prefix, _rest} -> prefix <> "..."
      {:incomplete, prefix, _rest} -> prefix <> "..."
      valid -> valid
    end
  end

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
