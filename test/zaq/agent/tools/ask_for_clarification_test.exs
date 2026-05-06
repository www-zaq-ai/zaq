defmodule Zaq.Agent.Tools.AskForClarificationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.AskForClarification

  describe "run/2" do
    test "returns clarification_needed with reason and question" do
      params = %{
        reason: "The question could refer to multiple products.",
        question: "Are you asking about Product A or Product B?"
      }

      assert {:ok, result} = AskForClarification.run(params, %{})
      assert result.clarification_needed == true
      assert result.reason == "The question could refer to multiple products."
      assert result.question == "Are you asking about Product A or Product B?"
    end
  end
end
