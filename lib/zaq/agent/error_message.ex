defmodule Zaq.Agent.ErrorMessage do
  @moduledoc """
  Canonical user-facing error message mapping for agent pipeline failures.

  Keeps error translation at the agent layer so all channels (BO, Mattermost,
  email, etc.) receive the same message payload.
  """

  @default_message "Something went wrong while answering your question. Please try again."
  @guard_message "I can't help with that request, but I'm here to help with other questions you might have."
  @credential_reasons [
    :personal_credential_required,
    :global_credential_missing,
    :credential_revoked,
    :credential_expired,
    :credential_unavailable,
    :credential_refresh_busy,
    :credential_refresh_failed,
    :provider_authentication_failed,
    :person_unavailable
  ]

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

  def from_reason(%{reason: reason} = failure, _fallback) when reason in @credential_reasons,
    do: credential_message(reason, Map.get(failure, :owner_type))

  def from_reason({:persist_failed, :trace_artifact_too_large}, _fallback),
    do:
      "One or more attachments are too large to store in the conversation. Please retry with smaller attachments."

  def from_reason({:persist_failed, _reason}, _fallback),
    do: "I couldn't save this exchange, so I can't safely deliver the answer. Please try again."

  def from_reason({:request_transformer, inner}, fallback), do: from_reason(inner, fallback)

  def from_reason({:context_window_exceeded, :mandatory_payload_too_large}, _fallback),
    do:
      "This request exceeds the selected model's context window. Shorten the request or ask an administrator to increase the agent's Model Context Window setting."

  def from_reason({:context_window_exceeded, :no_input_budget}, _fallback),
    do:
      "The selected agent's Model Context Window setting is too small for the reserved response size. Ask an administrator to increase the setting."

  def from_reason({:context_window_exceeded, _reason}, _fallback),
    do:
      "This request exceeds the selected model's context window. Shorten the request or adjust the agent configuration before trying again."

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
    do: provider_error_message(err.status)

  def from_reason(%ReqLLM.Error.API.Response{} = err, _fallback),
    do: provider_error_message(err.status)

  # Stream errors wrap an inner Request error as `cause` — unwrap and delegate.
  def from_reason(%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{} = inner}, fallback),
    do: from_reason(inner, fallback)

  # Jido wraps agent failures as {:failed, :error, reason} — unwrap and delegate.
  def from_reason({:failed, :error, inner}, fallback),
    do: from_reason(inner, fallback)

  def from_reason({:incomplete_response, _finish_reason}, _fallback),
    do: "The AI service is temporarily unavailable."

  def from_reason(_reason, fallback) when is_binary(fallback) and fallback != "",
    do: fallback

  def from_reason(_reason, _fallback),
    do: @default_message

  @doc """
  Returns the structured error type atom for a reason, or `nil` if not a known type.

  Used by pipeline/executor to set `error_type` in the result map so all channels
  can render budget exceeded (and future typed errors) in their own way.
  """
  @spec error_type_for(term()) :: atom() | nil
  def error_type_for(%ReqLLM.Error.API.Request{
        response_body: %{"error" => %{"type" => "budget_exceeded"}}
      }),
      do: :budget_exceeded

  def error_type_for(%ReqLLM.Error.API.Request{response_body: %{"type" => "budget_exceeded"}}),
    do: :budget_exceeded

  def error_type_for(%ReqLLM.Error.API.Stream{cause: inner}), do: error_type_for(inner)
  def error_type_for({:failed, :error, inner}), do: error_type_for(inner)
  def error_type_for({:request_transformer, inner}), do: error_type_for(inner)
  def error_type_for({:context_window_exceeded, _reason}), do: :context_window_exceeded
  def error_type_for(%{reason: reason}) when reason in @credential_reasons, do: reason
  def error_type_for(_), do: nil

  @doc """
  Returns the safe recovery category for a failure.

  Personal recovery is returned only when the reason itself requires a personal
  credential or trusted resolver provenance identifies the selected grant as personal.
  """
  @spec recovery_for(term()) :: :personal_credentials | :contact_administrator | :retry | nil
  def recovery_for(%{reason: :personal_credential_required}), do: :personal_credentials

  def recovery_for(%{reason: reason, owner_type: "person"})
      when reason in [
             :credential_revoked,
             :credential_expired,
             :credential_unavailable,
             :credential_refresh_failed,
             :provider_authentication_failed
           ],
      do: :personal_credentials

  def recovery_for(%{reason: :credential_refresh_busy}), do: :retry

  def recovery_for(%{reason: reason}) when reason in @credential_reasons,
    do: :contact_administrator

  def recovery_for(%ReqLLM.Error.API.Request{status: status})
      when status == 429 or (is_integer(status) and status >= 500),
      do: :retry

  def recovery_for(%ReqLLM.Error.API.Response{status: status})
      when is_integer(status) and status >= 500,
      do: :retry

  def recovery_for(%ReqLLM.Error.API.Stream{cause: inner}), do: recovery_for(inner)
  def recovery_for({:failed, :error, inner}), do: recovery_for(inner)
  def recovery_for({:request_transformer, inner}), do: recovery_for(inner)
  def recovery_for(_), do: nil

  @spec retryable?(term()) :: boolean()
  def retryable?(reason), do: recovery_for(reason) == :retry

  @doc """
  Adds trusted selected-credential ownership to provider authentication failures.

  Other failures are returned unchanged. Provider payloads are deliberately not
  retained in the enriched reason.
  """
  @spec with_credential_owner(term(), String.t() | nil) :: term()
  def with_credential_owner(%ReqLLM.Error.API.Request{status: status}, owner_type)
      when status in [401, 403] and owner_type in ["person", "org"],
      do: %{reason: :provider_authentication_failed, owner_type: owner_type}

  def with_credential_owner(%ReqLLM.Error.API.Stream{cause: inner} = reason, owner_type) do
    case with_credential_owner(inner, owner_type) do
      ^inner -> reason
      enriched -> enriched
    end
  end

  def with_credential_owner({:failed, :error, inner} = reason, owner_type) do
    case with_credential_owner(inner, owner_type) do
      ^inner -> reason
      enriched -> enriched
    end
  end

  def with_credential_owner(reason, _owner_type), do: reason

  @doc "Returns an allowlisted reason suitable for public result metadata."
  @spec public_reason_for(term()) :: atom()
  def public_reason_for(%{reason: reason}) when reason in @credential_reasons, do: reason

  def public_reason_for(%ReqLLM.Error.API.Request{
        response_body: %{"error" => %{"type" => "budget_exceeded"}}
      }),
      do: :budget_exceeded

  def public_reason_for(%ReqLLM.Error.API.Request{response_body: %{"type" => "budget_exceeded"}}),
    do: :budget_exceeded

  def public_reason_for(%ReqLLM.Error.API.Request{status: status}) when status in [401, 403],
    do: :provider_authentication_failed

  def public_reason_for(%ReqLLM.Error.API.Request{status: 429}), do: :provider_rate_limited

  def public_reason_for(%ReqLLM.Error.API.Request{status: status})
      when is_integer(status) and status >= 500,
      do: :provider_unavailable

  def public_reason_for(%ReqLLM.Error.API.Request{}), do: :provider_request_rejected
  def public_reason_for(%ReqLLM.Error.API.Response{}), do: :provider_response_failed
  def public_reason_for(%ReqLLM.Error.API.Stream{cause: inner}), do: public_reason_for(inner)
  def public_reason_for({:failed, :error, inner}), do: public_reason_for(inner)
  def public_reason_for({:request_transformer, inner}), do: public_reason_for(inner)
  def public_reason_for({:context_window_exceeded, _reason}), do: :context_window_exceeded
  def public_reason_for({:persist_failed, _reason}), do: :persist_failed
  def public_reason_for({:timeout, _duration}), do: :timeout
  def public_reason_for(reason) when is_atom(reason), do: reason
  def public_reason_for(_reason), do: :agent_execution_failed

  defp credential_message(:personal_credential_required, _scope),
    do:
      "Personal AI credentials are required for this agent. Add them in the People portal and try again."

  defp credential_message(:global_credential_missing, _scope),
    do:
      "AI credentials have not been configured for this agent. Ask an administrator to configure them."

  defp credential_message(:person_unavailable, _scope),
    do:
      "Your identity could not be verified for this request. Ask an administrator to check your People access."

  defp credential_message(:credential_refresh_busy, "person"),
    do: "Your personal AI credentials are being refreshed. Please try again shortly."

  defp credential_message(:credential_refresh_busy, _scope),
    do: "The AI credentials are being refreshed. Please try again shortly."

  defp credential_message(:credential_revoked, "person"),
    do:
      "Your personal AI credentials were revoked. Update or reconnect them in the People portal and try again."

  defp credential_message(:credential_expired, "person"),
    do:
      "Your personal AI credentials expired. Update or reconnect them in the People portal and try again."

  defp credential_message(:credential_unavailable, "person"),
    do:
      "Your personal AI credentials are invalid or unavailable. Update or reconnect them in the People portal and try again."

  defp credential_message(:credential_refresh_failed, "person"),
    do:
      "Your personal AI credentials could not be refreshed. Reconnect them in the People portal and try again."

  defp credential_message(:provider_authentication_failed, "person"),
    do:
      "Your personal AI credentials were rejected by the provider. Update or reconnect them in the People portal and try again."

  defp credential_message(:provider_authentication_failed, _scope),
    do:
      "The AI provider rejected the configured credentials. Ask an administrator to update them."

  defp credential_message(:credential_revoked, _scope),
    do:
      "The AI credentials used for this request were revoked. Ask an administrator to update them."

  defp credential_message(:credential_expired, _scope),
    do: "The configured AI credentials expired. Ask an administrator to update them."

  defp credential_message(:credential_unavailable, _scope),
    do:
      "The configured AI credentials are invalid or unavailable. Ask an administrator to update them."

  defp credential_message(:credential_refresh_failed, _scope),
    do:
      "The configured AI credentials could not be refreshed. Ask an administrator to reconnect them."

  defp provider_error_message(status) when is_integer(status) and status >= 500,
    do: "The AI service is temporarily unavailable. Please try again shortly."

  defp provider_error_message(429),
    do: "The AI provider is rate limiting requests. Please try again shortly."

  defp provider_error_message(status) when status in [401, 403],
    do:
      "The AI provider rejected the credentials used for this request. Update the credentials or ask an administrator for help."

  defp provider_error_message(status) when is_integer(status) and status >= 400,
    do:
      "The AI provider rejected the request. Check the request or ask an administrator for help."

  defp provider_error_message(_status),
    do: "There was an error communicating with the AI provider. Please try again."
end
