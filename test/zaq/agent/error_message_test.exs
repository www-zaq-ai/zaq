defmodule Zaq.Agent.ErrorMessageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.ErrorMessage

  @default_message "Something went wrong while answering your question. Please try again."
  @known_reasons [
    :leaked,
    :guard_blocked,
    :halted,
    :dispatch_error,
    :no_results,
    :blocked,
    :provider_not_supported
  ]

  describe "from_reason/2" do
    test "maps prompt guard reasons to shared guard message" do
      expected =
        "I can't help with that request, but I'm here to help with other questions you might have."

      assert ErrorMessage.from_reason(:guard_blocked) == expected
      assert ErrorMessage.from_reason(:leaked) == expected
    end

    test "maps halted reason" do
      assert ErrorMessage.from_reason(:halted) == "Request was halted by a pipeline hook."
    end

    test "maps no_results and blocked reasons" do
      expected = "I couldn't find relevant information to answer your question."
      assert ErrorMessage.from_reason(:no_results) == expected
      assert ErrorMessage.from_reason(:blocked) == expected
    end

    test "maps dispatch_error reason" do
      assert ErrorMessage.from_reason(:dispatch_error) ==
               "Sorry, something went wrong. Please try again."
    end

    test "maps provider_not_supported to a clear message" do
      assert ErrorMessage.from_reason(:provider_not_supported) ==
               "The selected AI provider is not supported. Please check your agent configuration."
    end

    test "maps credential resolution failures to actionable messages" do
      assert ErrorMessage.from_reason(%{reason: :personal_credential_required}) ==
               "Personal AI credentials are required for this agent. Add them in the People portal and try again."

      assert ErrorMessage.from_reason(%{reason: :credential_revoked, owner_type: "person"}) ==
               "Your personal AI credentials were revoked. Update or reconnect them in the People portal and try again."

      assert ErrorMessage.from_reason(%{reason: :credential_expired, owner_type: "person"}) ==
               "Your personal AI credentials expired. Update or reconnect them in the People portal and try again."

      assert ErrorMessage.from_reason(%{reason: :credential_refresh_failed, owner_type: "person"}) ==
               "Your personal AI credentials could not be refreshed. Reconnect them in the People portal and try again."

      assert ErrorMessage.from_reason(%{reason: :credential_refresh_busy, owner_type: "person"}) ==
               "Your personal AI credentials are being refreshed. Please try again shortly."

      assert ErrorMessage.from_reason(%{reason: :global_credential_missing}) ==
               "AI credentials have not been configured for this agent. Ask an administrator to configure them."

      assert ErrorMessage.from_reason(%{reason: :credential_expired, owner_type: "org"}) ==
               "The configured AI credentials expired. Ask an administrator to update them."

      assert ErrorMessage.from_reason(%{reason: :person_unavailable}) ==
               "Your identity could not be verified for this request. Ask an administrator to check your People access."
    end

    test "does not claim an unscoped credential failure is personal" do
      assert ErrorMessage.from_reason(%{credential_id: 42, reason: :credential_revoked}) ==
               "The AI credentials used for this request were revoked. Ask an administrator to update them."
    end

    test "uses trusted runtime ownership for provider authentication failures" do
      provider_error = %ReqLLM.Error.API.Request{
        reason: "invalid key with secret detail",
        status: 401,
        response_body: %{"secret" => "provider-secret"}
      }

      personal = ErrorMessage.with_credential_owner(provider_error, "person")
      organization = ErrorMessage.with_credential_owner(provider_error, "org")

      assert ErrorMessage.from_reason(personal) ==
               "Your personal AI credentials were rejected by the provider. Update or reconnect them in the People portal and try again."

      assert ErrorMessage.recovery_for(personal) == :personal_credentials

      assert ErrorMessage.from_reason(organization) ==
               "The AI provider rejected the configured credentials. Ask an administrator to update them."

      assert ErrorMessage.recovery_for(organization) == :contact_administrator
      refute ErrorMessage.from_reason(personal) =~ "provider-secret"
      refute ErrorMessage.from_reason(personal) =~ "secret detail"
    end

    test "maps persistence failures to safe user-facing messages" do
      assert ErrorMessage.from_reason({:persist_failed, :trace_artifact_too_large}) ==
               "One or more attachments are too large to store in the conversation. Please retry with smaller attachments."

      assert ErrorMessage.from_reason({:persist_failed, :db_down}) ==
               "I couldn't save this exchange, so I can't safely deliver the answer. Please try again."
    end

    test "maps incomplete provider responses to temporarily unavailable" do
      assert ErrorMessage.from_reason({:incomplete_response, :incomplete}) ==
               "The AI service is temporarily unavailable."

      assert ErrorMessage.from_reason({:failed, :error, {:incomplete_response, :error}}) ==
               "The AI service is temporarily unavailable."
    end

    test "maps context-window failures to actionable user-facing messages" do
      assert ErrorMessage.from_reason(
               {:request_transformer, {:context_window_exceeded, :mandatory_payload_too_large}},
               "fallback"
             ) ==
               "This request exceeds the selected model's context window. Shorten the request or ask an administrator to increase the agent's Model Context Window setting."

      assert ErrorMessage.from_reason({:context_window_exceeded, :no_input_budget}) ==
               "The selected agent's Model Context Window setting is too small for the reserved response size. Ask an administrator to increase the setting."
    end

    test "maps ReqLLM request failures without exposing provider details" do
      error = %ReqLLM.Error.API.Request{reason: "Budget has been exceeded.", status: 429}

      assert ErrorMessage.from_reason(error) ==
               "The AI provider is rate limiting requests. Please try again shortly."
    end

    test "maps ReqLLM response failures without exposing provider details" do
      error = %ReqLLM.Error.API.Response{reason: "No message in response.", status: 200}

      assert ErrorMessage.from_reason(error) ==
               "There was an error communicating with the AI provider. Please try again."
    end

    test "falls back to default for ReqLLM API errors with blank reason" do
      error = %ReqLLM.Error.API.Request{reason: "", status: 429}

      assert ErrorMessage.from_reason(error) ==
               "The AI provider is rate limiting requests. Please try again shortly."
    end

    property "returns fallback for unknown reasons when fallback is non-empty" do
      check all(
              reason <- atom(:alphanumeric),
              reason not in @known_reasons,
              fallback <- string(:alphanumeric, min_length: 1)
            ) do
        assert ErrorMessage.from_reason(reason, fallback) == fallback
      end
    end

    property "returns default for unknown reasons when fallback is nil" do
      check all(
              reason <- atom(:alphanumeric),
              reason not in @known_reasons
            ) do
        assert ErrorMessage.from_reason(reason) == @default_message
      end
    end

    property "returns default for unknown reasons when fallback is blank" do
      check all(
              reason <- atom(:alphanumeric),
              reason not in @known_reasons
            ) do
        assert ErrorMessage.from_reason(reason, "") == @default_message
      end
    end

    test "maps nested budget_exceeded response_body to credit exhaustion message" do
      error = %ReqLLM.Error.API.Request{
        response_body: %{"error" => %{"type" => "budget_exceeded"}},
        status: 429
      }

      assert ErrorMessage.from_reason(error) == "Your AI credits have run out."
    end

    test "maps flat budget_exceeded response_body to credit exhaustion message" do
      error = %ReqLLM.Error.API.Request{
        response_body: %{"type" => "budget_exceeded"},
        status: 429
      }

      assert ErrorMessage.from_reason(error) == "Your AI credits have run out."
    end

    test "never exposes a non-JSON provider response body" do
      bad_body = %{"key" => {:not, :json}}
      error = %ReqLLM.Error.API.Request{response_body: bad_body, status: 500}
      result = ErrorMessage.from_reason(error)
      assert result == "The AI service is temporarily unavailable. Please try again shortly."
      refute String.contains?(result, "not")
    end

    property "credential messages never expose arbitrary error payload values" do
      check all(value <- string(:alphanumeric, min_length: 8)) do
        secret = "__secret_#{value}__"

        reason = %{
          credential_id: secret,
          reason: :credential_unavailable,
          owner_type: "person",
          provider_body: secret
        }

        refute ErrorMessage.from_reason(reason) =~ secret
      end
    end
  end

  describe "error_type_for/1" do
    test "returns :budget_exceeded for nested error.type body" do
      error = %ReqLLM.Error.API.Request{
        response_body: %{"error" => %{"type" => "budget_exceeded"}}
      }

      assert ErrorMessage.error_type_for(error) == :budget_exceeded
    end

    test "returns :budget_exceeded for flat type body" do
      error = %ReqLLM.Error.API.Request{
        response_body: %{"type" => "budget_exceeded"}
      }

      assert ErrorMessage.error_type_for(error) == :budget_exceeded
    end

    test "unwraps Stream cause and delegates to inner error" do
      inner = %ReqLLM.Error.API.Request{
        response_body: %{"type" => "budget_exceeded"}
      }

      stream_error = %ReqLLM.Error.API.Stream{cause: inner}
      assert ErrorMessage.error_type_for(stream_error) == :budget_exceeded
    end

    test "unwraps {:failed, :error, inner} tuple" do
      inner = %ReqLLM.Error.API.Request{
        response_body: %{"error" => %{"type" => "budget_exceeded"}}
      }

      assert ErrorMessage.error_type_for({:failed, :error, inner}) == :budget_exceeded
    end

    test "returns :context_window_exceeded for nested transformer failures" do
      reason =
        {:failed, :error,
         {:request_transformer, {:context_window_exceeded, :mandatory_payload_too_large}}}

      assert ErrorMessage.error_type_for(reason) == :context_window_exceeded
    end

    test "returns safe credential failure types" do
      assert ErrorMessage.error_type_for(%{reason: :credential_revoked, owner_type: "person"}) ==
               :credential_revoked

      assert ErrorMessage.error_type_for(%{reason: :global_credential_missing}) ==
               :global_credential_missing
    end

    test "returns nil for unrecognised reasons" do
      assert ErrorMessage.error_type_for(:some_atom) == nil
      assert ErrorMessage.error_type_for(%ReqLLM.Error.API.Request{response_body: %{}}) == nil
    end
  end

  describe "recovery_for/1" do
    test "offers People credential recovery only for trusted personal failures" do
      assert ErrorMessage.recovery_for(%{reason: :personal_credential_required}) ==
               :personal_credentials

      assert ErrorMessage.recovery_for(%{reason: :credential_expired, owner_type: "person"}) ==
               :personal_credentials

      assert ErrorMessage.recovery_for(%{reason: :credential_expired, owner_type: "org"}) ==
               :contact_administrator

      assert ErrorMessage.recovery_for(%{reason: :credential_expired}) ==
               :contact_administrator
    end

    test "marks transient failures for retry" do
      assert ErrorMessage.recovery_for(%{reason: :credential_refresh_busy, owner_type: "person"}) ==
               :retry

      assert ErrorMessage.retryable?(%{reason: :credential_refresh_busy})
      refute ErrorMessage.retryable?(%{reason: :credential_revoked, owner_type: "person"})
    end
  end

  describe "public_reason_for/1" do
    test "keeps only the allowlisted reason from credential failures" do
      failure = %{
        credential_id: 42,
        reason: :credential_revoked,
        owner_type: "person",
        provider_body: "secret"
      }

      assert ErrorMessage.public_reason_for(failure) == :credential_revoked
    end

    test "normalizes provider and unknown failures" do
      assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Request{status: 401}) ==
               :provider_authentication_failed

      assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Request{status: 429}) ==
               :provider_rate_limited

      assert ErrorMessage.public_reason_for({:failed, :error, %{private: "detail"}}) ==
               :agent_execution_failed
    end
  end
end
