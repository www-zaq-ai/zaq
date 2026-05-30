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
        "I can’t help with that request, but I’m here to help with other questions you might have."

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
      assert ErrorMessage.from_reason(error) == "Budget has been exceeded."
    end

    test "surfaces reason from ReqLLM API response errors" do
      error = %ReqLLM.Error.API.Response{reason: "No message in response.", status: 200}
      assert ErrorMessage.from_reason(error) == "No message in response."
    end

    test "falls back to default for ReqLLM API errors with blank reason" do
      error = %ReqLLM.Error.API.Request{reason: "", status: 429}
      assert ErrorMessage.from_reason(error) == @default_message
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
  end
end
