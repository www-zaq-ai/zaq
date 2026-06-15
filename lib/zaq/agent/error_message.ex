defmodule Zaq.Agent.ErrorMessage do
  @moduledoc """
  Canonical user-facing error message mapping for agent pipeline failures.

  Keeps error translation at the agent layer so all channels (BO, Mattermost,
  email, etc.) receive the same message payload.
  """

  @default_message "Something went wrong while answering your question. Please try again."
  @guard_message "I can't help with that request, but I'm here to help with other questions you might have."

  @spec from_reason(term(), String.t() | nil) :: String.t()
  def from_reason(reason, fallback \\ nil)

  def from_reason(reason, _fallback) when reason in [:leaked, :guard_blocked],
    do: @guard_message

  def from_reason(:halted, _fallback),
    do: "Request was halted by a pipeline hook."

  def from_reason(reason, _fallback) when reason in [:no_results, :blocked],
    do: "I couldn't find relevant information to answer your question."

  def from_reason(:dispatch_error, _fallback),
    do: "Sorry, something went wrong. Please try again."

  def from_reason(:provider_not_supported, _fallback),
    do: "The selected AI provider is not supported. Please check your agent configuration."

  def from_reason(
        %ReqLLM.Error.API.Request{response_body: %{"error" => %{"type" => "budget_exceeded"}}},
        _fallback
      ),
      do: "Your AI credits have run out."

  def from_reason(
        %ReqLLM.Error.API.Request{response_body: %{"type" => "budget_exceeded"}},
        _fallback
      ),
      do: "Your AI credits have run out."

  def from_reason(%ReqLLM.Error.API.Request{} = err, _fallback),
    do: provider_error_message(err.status, build_detail(err.reason, err.response_body))

  def from_reason(%ReqLLM.Error.API.Response{} = err, _fallback),
    do: provider_error_message(err.status, build_detail(err.reason, err.response_body))

  # Stream errors wrap an inner Request error as `cause` — unwrap and delegate.
  def from_reason(%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{} = inner}, fallback),
    do: from_reason(inner, fallback)

  # Jido wraps agent failures as {:failed, :error, reason} — unwrap and delegate.
  def from_reason({:failed, :error, inner}, fallback),
    do: from_reason(inner, fallback)

  def from_reason(_reason, fallback) when is_binary(fallback) and fallback != "",
    do: fallback

  def from_reason(_reason, _fallback),
    do: @default_message

  @doc """
  Returns the structured error type atom for a reason, or `nil` if not a known type.

  Used by pipeline/executor to set `error_type` in the result map so all channels
  can render budget exceeded (and future typed errors) in their own way.
  """
  @spec error_type_for(term()) :: :budget_exceeded | nil
  def error_type_for(%ReqLLM.Error.API.Request{
        response_body: %{"error" => %{"type" => "budget_exceeded"}}
      }),
      do: :budget_exceeded

  def error_type_for(%ReqLLM.Error.API.Request{response_body: %{"type" => "budget_exceeded"}}),
    do: :budget_exceeded

  def error_type_for(%ReqLLM.Error.API.Stream{cause: inner}), do: error_type_for(inner)
  def error_type_for({:failed, :error, inner}), do: error_type_for(inner)
  def error_type_for(_), do: nil

  defp provider_error_message(status, detail) do
    summary =
      cond do
        is_integer(status) and status >= 500 -> "The AI service is temporarily unavailable."
        is_integer(status) and status >= 400 -> "The AI provider rejected the request."
        true -> "There was an error communicating with the AI provider."
      end

    if detail && detail != "", do: "#{summary}\n#{detail}", else: summary
  end

  # Build a human-useful detail string from the provider response.
  # Shows the full response body as JSON when available; falls back to the reason string.
  defp build_detail(reason, response_body) do
    cond do
      is_map(response_body) and map_size(response_body) > 0 ->
        case Jason.encode(response_body, pretty: true) do
          {:ok, json} -> json
          _ -> inspect(response_body, pretty: true)
        end

      is_binary(reason) and reason != "" ->
        reason

      true ->
        nil
    end
  end
end
