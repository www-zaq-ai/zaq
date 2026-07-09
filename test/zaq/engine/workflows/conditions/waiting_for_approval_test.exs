defmodule Zaq.Engine.Workflows.Conditions.WaitingForApprovalTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.Conditions.WaitingForApproval

  describe "message/1" do
    test "includes step_name and run_id" do
      ex = %WaitingForApproval{
        step_name: "review",
        run_id: "run-123",
        approval_token: "tok-abc"
      }

      msg = WaitingForApproval.message(ex)
      assert msg =~ "review"
      assert msg =~ "run-123"
    end
  end

  describe "raise/rescue" do
    test "can be raised and rescued" do
      token = Ecto.UUID.generate()

      result =
        try do
          raise WaitingForApproval, step_name: "review", run_id: "r1", approval_token: token
        rescue
          e in WaitingForApproval -> {:caught, e}
        end

      assert {:caught, e} = result
      assert e.step_name == "review"
      assert e.run_id == "r1"
      assert e.approval_token == token
    end

    test "is not caught by a generic rescue clause for a different exception" do
      assert_raise WaitingForApproval, fn ->
        raise WaitingForApproval, step_name: "s", run_id: "r", approval_token: "t"
      end
    end
  end
end
