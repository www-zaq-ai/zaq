defmodule Zaq.Agent.ErrorMessageTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.ErrorMessage

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

    test "maps dispatch_error reason" do
      assert ErrorMessage.from_reason(:dispatch_error) ==
               "Sorry, something went wrong. Please try again."
    end

    test "uses explicit fallback for unknown reasons" do
      assert ErrorMessage.from_reason(:unknown_error, "custom fallback") == "custom fallback"
    end

    test "uses default message when reason is unknown and fallback is missing" do
      assert ErrorMessage.from_reason(:unknown_error) ==
               "Something went wrong while answering your question. Please try again."
    end

    test "uses default message when fallback is blank" do
      assert ErrorMessage.from_reason(:unknown_error, "") ==
               "Something went wrong while answering your question. Please try again."
    end
  end
end
