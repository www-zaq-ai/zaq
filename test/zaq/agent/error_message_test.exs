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

      expected =
        "This request exceeds the selected model's context window. Shorten the request or adjust the agent configuration before trying again."

      assert ErrorMessage.from_reason(
               {:context_window_exceeded, :unknown_limit_reason},
               "fallback must not win"
             ) ==
               expected

      assert ErrorMessage.from_reason(
               {:request_transformer, {:context_window_exceeded, :unknown_limit_reason}},
               "fallback must not win"
             ) == expected
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

    test "uses non-person guidance without trusted personal ownership" do
      rows = [
        {:credential_refresh_busy,
         "The AI credentials are being refreshed. Please try again shortly.", :retry, true},
        {:credential_unavailable,
         "The configured AI credentials are invalid or unavailable. Ask an administrator to update them.",
         :contact_administrator, false},
        {:credential_refresh_failed,
         "The configured AI credentials could not be refreshed. Ask an administrator to reconnect them.",
         :contact_administrator, false}
      ]

      for {reason, message, recovery, retryable} <- rows,
          owner <- ["org", :omitted, nil] do
        failure = %{reason: reason, credential_id: 42, provider_body: "synthetic-secret"}
        failure = if owner == :omitted, do: failure, else: Map.put(failure, :owner_type, owner)

        assert ErrorMessage.from_reason(failure, "fallback must not win") == message
        assert ErrorMessage.recovery_for(failure) == recovery
        assert ErrorMessage.retryable?(failure) == retryable
        assert ErrorMessage.public_reason_for(failure) == reason
        assert ErrorMessage.error_type_for(failure) == reason
      end
    end

    test "gives neutral guidance for unowned provider authentication errors" do
      expected =
        "The AI provider rejected the credentials used for this request. Update the credentials or ask an administrator for help."

      for error <- [
            %ReqLLM.Error.API.Request{status: 401, reason: "synthetic-secret"},
            %ReqLLM.Error.API.Request{status: 403, reason: "synthetic-secret"},
            %ReqLLM.Error.API.Response{status: 401, reason: "synthetic-secret"}
          ] do
        assert ErrorMessage.from_reason(error, "unrelated fallback") == expected
        assert ErrorMessage.recovery_for(error) == nil
        refute ErrorMessage.retryable?(error)
      end
    end

    test "distinguishes ordinary client errors from special provider statuses" do
      rejected =
        "The AI provider rejected the request. Check the request or ask an administrator for help."

      for error <- [
            %ReqLLM.Error.API.Request{status: 400, reason: "synthetic-secret"},
            %ReqLLM.Error.API.Request{status: 422, reason: "synthetic-secret"},
            %ReqLLM.Error.API.Request{status: 499, reason: "synthetic-secret"},
            %ReqLLM.Error.API.Response{status: 422, reason: "synthetic-secret"}
          ] do
        assert ErrorMessage.from_reason(error, "unrelated fallback") == rejected
      end

      assert ErrorMessage.from_reason(%ReqLLM.Error.API.Request{status: 399}) ==
               "There was an error communicating with the AI provider. Please try again."

      assert ErrorMessage.from_reason(%ReqLLM.Error.API.Request{status: 500}) ==
               "The AI service is temporarily unavailable. Please try again shortly."
    end

    property "trusted wrapped authentication discards arbitrary payloads" do
      check all(
              status <- member_of([401, 403]),
              owner <- member_of(["person", "org"]),
              payload <- string(:alphanumeric, min_length: 1, max_length: 64),
              tags <- list_of(member_of([:failed, :stream]), min_length: 1, max_length: 4)
            ) do
        secret = "__secret_#{payload}__"

        inner = %ReqLLM.Error.API.Request{
          status: status,
          reason: secret,
          response_body: %{"secret" => secret}
        }

        wrapped = wrap_reason(inner, tags)
        enriched = ErrorMessage.with_credential_owner(wrapped, owner)

        assert enriched == %{reason: :provider_authentication_failed, owner_type: owner}
        assert ErrorMessage.public_reason_for(enriched) == :provider_authentication_failed

        expected_recovery =
          if owner == "person", do: :personal_credentials, else: :contact_administrator

        assert ErrorMessage.recovery_for(enriched) == expected_recovery
        refute ErrorMessage.retryable?(enriched)
      end
    end

    property "absent or invalid provenance never enriches wrappers" do
      check all(
              owner <- member_of([nil, "", "unknown", :person]),
              status <- member_of([401, 403]),
              payload <- string(:alphanumeric, min_length: 1, max_length: 64),
              tags <- list_of(member_of([:failed, :stream]), min_length: 1, max_length: 4)
            ) do
        secret = "__secret_#{payload}__"

        inner = %ReqLLM.Error.API.Request{
          status: status,
          reason: secret,
          response_body: %{"secret" => secret}
        }

        wrapped = wrap_reason(inner, tags)
        assert ErrorMessage.with_credential_owner(wrapped, owner) === wrapped
        assert ErrorMessage.recovery_for(wrapped) == nil
        refute ErrorMessage.retryable?(wrapped)
      end
    end

    property "non-person credential guidance ignores arbitrary extra details" do
      check all(
              {reason, message, recovery, retryable} <-
                member_of([
                  {:credential_refresh_busy,
                   "The AI credentials are being refreshed. Please try again shortly.", :retry,
                   true},
                  {:credential_unavailable,
                   "The configured AI credentials are invalid or unavailable. Ask an administrator to update them.",
                   :contact_administrator, false},
                  {:credential_refresh_failed,
                   "The configured AI credentials could not be refreshed. Ask an administrator to reconnect them.",
                   :contact_administrator, false}
                ]),
              owner <- member_of([:absent, nil, "org", "unknown", :person]),
              payload <- string(:alphanumeric, min_length: 1, max_length: 64)
            ) do
        failure = %{reason: reason, credential_id: 42, provider_body: "__secret_#{payload}__"}
        failure = if owner == :absent, do: failure, else: Map.put(failure, :owner_type, owner)

        assert ErrorMessage.from_reason(failure, "fallback must not win") == message
        assert ErrorMessage.recovery_for(failure) == recovery
        assert ErrorMessage.retryable?(failure) == retryable
        assert ErrorMessage.public_reason_for(failure) == reason
        assert ErrorMessage.error_type_for(failure) == reason
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

    test "classifies provider recovery without inferring credential ownership" do
      for status <- [500, 503, 599] do
        assert ErrorMessage.recovery_for(%ReqLLM.Error.API.Response{status: status}) == :retry
        assert ErrorMessage.retryable?(%ReqLLM.Error.API.Response{status: status})
      end

      for status <- [499, 429, 401, nil, "503"] do
        error = %ReqLLM.Error.API.Response{status: status}
        assert ErrorMessage.recovery_for(error) == nil
        refute ErrorMessage.retryable?(error)
      end

      for status <- [429, 500, 503] do
        assert ErrorMessage.recovery_for(%ReqLLM.Error.API.Request{status: status}) == :retry
        assert ErrorMessage.retryable?(%ReqLLM.Error.API.Request{status: status})
      end

      for status <- [428, 430, 499, 401, 403, nil, "500"] do
        error = %ReqLLM.Error.API.Request{status: status}
        assert ErrorMessage.recovery_for(error) == nil
        refute ErrorMessage.retryable?(error)
      end
    end

    test "propagates recovery through failure wrappers" do
      for {status, expected} <- [{503, :retry}, {401, nil}] do
        inner = %ReqLLM.Error.API.Request{status: status}
        stream = %ReqLLM.Error.API.Stream{cause: inner}
        nested = {:failed, :error, {:request_transformer, %ReqLLM.Error.API.Stream{cause: inner}}}

        for reason <- [{:failed, :error, inner}, stream, nested] do
          assert ErrorMessage.recovery_for(reason) == expected
          assert ErrorMessage.retryable?(reason) == (expected == :retry)
        end
      end
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

    test "normalizes both budget body shapes before status classification" do
      assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Request{
               status: 401,
               response_body: %{
                 "error" => %{"type" => "budget_exceeded", "detail" => "synthetic-secret"}
               }
             }) == :budget_exceeded

      assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Request{
               status: 429,
               response_body: %{"type" => "budget_exceeded", "detail" => "synthetic-secret"}
             }) == :budget_exceeded
    end

    test "normalizes non-budget provider failures to safe public atoms" do
      for status <- [400, 422, 499, nil] do
        assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Request{
                 status: status,
                 reason: "synthetic-secret",
                 response_body: %{"detail" => "synthetic-secret"}
               }) == :provider_request_rejected
      end

      for status <- [200, 503] do
        assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Response{
                 status: status,
                 reason: "synthetic-secret"
               }) == :provider_response_failed
      end

      for status <- [500, 503] do
        assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Request{status: status}) ==
                 :provider_unavailable
      end

      for reason <- [:trace_artifact_too_large, :db_down, %{detail: "synthetic-secret"}] do
        assert ErrorMessage.public_reason_for({:persist_failed, reason}) == :persist_failed
      end

      request = %ReqLLM.Error.API.Request{status: 422}

      assert ErrorMessage.public_reason_for(%ReqLLM.Error.API.Stream{cause: request}) ==
               :provider_request_rejected

      assert ErrorMessage.public_reason_for({:request_transformer, request}) ==
               :provider_request_rejected
    end
  end

  describe "with_credential_owner/2" do
    test "enriches trusted authentication failures and drops provider payloads" do
      for status <- [401, 403], owner <- ["person", "org"] do
        inner = %ReqLLM.Error.API.Request{
          status: status,
          reason: "synthetic-secret-detail",
          response_body: %{"secret" => "synthetic-provider-secret"}
        }

        result = ErrorMessage.with_credential_owner({:failed, :error, inner}, owner)
        assert result === %{reason: :provider_authentication_failed, owner_type: owner}
        assert ErrorMessage.public_reason_for(result) == :provider_authentication_failed

        expected_recovery =
          if owner == "person", do: :personal_credentials, else: :contact_administrator

        assert ErrorMessage.recovery_for(result) == expected_recovery
        refute ErrorMessage.retryable?(result)
      end
    end

    test "preserves unchanged wrappers and rejects invalid owners" do
      for owner <- ["unknown", :person, ""] do
        inner = %ReqLLM.Error.API.Request{status: 401, reason: "synthetic-secret-detail"}
        wrapped = {:failed, :error, inner}
        assert ErrorMessage.with_credential_owner(wrapped, owner) === wrapped
      end

      auth = %ReqLLM.Error.API.Request{status: 401, reason: "synthetic-secret-detail"}

      rate_limited = %ReqLLM.Error.API.Request{
        status: 429,
        response_body: %{"secret" => "secret"}
      }

      assert ErrorMessage.with_credential_owner({:failed, :error, rate_limited}, "person") ===
               {:failed, :error, rate_limited}

      assert ErrorMessage.with_credential_owner({:failed, :error, auth}, nil) ===
               {:failed, :error, auth}
    end

    test "recurses through Stream and failed wrappers" do
      inner = %ReqLLM.Error.API.Request{status: 403, reason: "synthetic-secret-detail"}

      assert ErrorMessage.with_credential_owner(
               {:failed, :error, %ReqLLM.Error.API.Stream{cause: inner}},
               "person"
             ) ==
               %{reason: :provider_authentication_failed, owner_type: "person"}

      assert ErrorMessage.with_credential_owner(
               %ReqLLM.Error.API.Stream{cause: {:failed, :error, inner}},
               "org"
             ) ==
               %{reason: :provider_authentication_failed, owner_type: "org"}

      unavailable = %ReqLLM.Error.API.Request{status: 500, response_body: %{"secret" => "secret"}}
      failed_stream = {:failed, :error, %ReqLLM.Error.API.Stream{cause: unavailable}}
      stream_failed = %ReqLLM.Error.API.Stream{cause: {:failed, :error, unavailable}}
      assert ErrorMessage.with_credential_owner(failed_stream, "person") === failed_stream
      assert ErrorMessage.with_credential_owner(stream_failed, "org") === stream_failed
    end
  end

  defp wrap_reason(reason, tags) do
    Enum.reduce(tags, reason, fn
      :failed, inner -> {:failed, :error, inner}
      :stream, inner -> %ReqLLM.Error.API.Stream{cause: inner}
    end)
  end
end
