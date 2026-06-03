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

    test "surfaces reason from ReqLLM API request errors (e.g. LiteLLM budget exceeded)" do
      error = %ReqLLM.Error.API.Request{reason: "Budget has been exceeded.", status: 429}

      assert ErrorMessage.from_reason(error) ==
               "The AI provider rejected the request.\nBudget has been exceeded."
    end

    test "surfaces reason from ReqLLM API response errors" do
      error = %ReqLLM.Error.API.Response{reason: "No message in response.", status: 200}

      assert ErrorMessage.from_reason(error) ==
               "There was an error communicating with the AI provider.\nNo message in response."
    end

    test "falls back to default for ReqLLM API errors with blank reason" do
      error = %ReqLLM.Error.API.Request{reason: "", status: 429}
      assert ErrorMessage.from_reason(error) == "The AI provider rejected the request."
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

    test "falls back to inspect when response_body is not JSON-encodable" do
      # Tuples are not JSON-serialisable — Jason.encode returns an error
      bad_body = %{"key" => {:not, :json}}
      error = %ReqLLM.Error.API.Request{response_body: bad_body, status: 500}
      result = ErrorMessage.from_reason(error)
      # Should still return a string containing the unavailable summary (status 500)
      assert String.contains?(result, "The AI service is temporarily unavailable.")
      assert String.contains?(result, "not")
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

    test "returns nil for unrecognised reasons" do
      assert ErrorMessage.error_type_for(:some_atom) == nil
      assert ErrorMessage.error_type_for(%ReqLLM.Error.API.Request{response_body: %{}}) == nil
    end
  end
end
