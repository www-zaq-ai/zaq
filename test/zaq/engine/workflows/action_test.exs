defmodule Zaq.Engine.Workflows.ActionTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.Test.{NonConformingAction, OkAction}

  describe "validate/1" do
    test "returns :ok for a fully conforming action module" do
      assert :ok = Action.validate(OkAction)
    end

    test "returns contract_violation for a loaded module missing all contract pieces" do
      assert {:error, {:contract_violation, NonConformingAction, missing}} =
               Action.validate(NonConformingAction)

      assert :on_success in missing
      assert :on_failure in missing
      assert :schema in missing
      assert :output_schema in missing
    end

    test "returns contract_violation with all required pieces when module does not exist" do
      assert {:error, {:contract_violation, Zaq.VeryNonExistentModule, missing}} =
               Action.validate(Zaq.VeryNonExistentModule)

      assert missing == [:on_success, :on_failure, :schema, :output_schema]
    end
  end
end
