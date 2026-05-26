defmodule Zaq.Agent.Tools.Workflow.ConditionTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Condition

  @ctx %{}

  describe "run/2 — all conditions pass" do
    test "atom-keyed input" do
      input = %{active: true, flagged: false, name: "John", age: 20, gender: "male"}

      conditions = [
        %{"key" => "active", "value" => true},
        %{"key" => "flagged", "value" => false}
      ]

      assert {:ok, %{passed: true, input: ^input}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "string-keyed input" do
      input = %{"active" => true, "flagged" => false}

      conditions = [
        %{"key" => "active", "value" => true},
        %{"key" => "flagged", "value" => false}
      ]

      assert {:ok, %{passed: true, input: ^input}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "empty conditions list always passes" do
      input = %{active: false}

      assert {:ok, %{passed: true}} =
               Condition.run(%{input: input, conditions: []}, @ctx)
    end
  end

  describe "run/2 — conditions fail with on_fail: :halt (default)" do
    test "returns error string listing failed condition keys" do
      input = %{active: false, flagged: true}

      conditions = [
        %{"key" => "active", "value" => true},
        %{"key" => "flagged", "value" => false}
      ]

      assert {:error, reason} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)

      assert String.starts_with?(reason, "condition_failed:")
      assert String.contains?(reason, "active")
      assert String.contains?(reason, "flagged")
    end

    test "partial failure — only failing key is in the error string" do
      input = %{active: true, flagged: true}

      conditions = [
        %{"key" => "active", "value" => true},
        %{"key" => "flagged", "value" => false}
      ]

      assert {:error, reason} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)

      assert reason == "condition_failed:flagged"
    end
  end

  describe "run/2 — conditions fail with on_fail: :continue" do
    test "returns ok with passed: false and failed_conditions" do
      input = %{active: false}

      conditions = [%{"key" => "active", "value" => true}]

      assert {:ok, %{passed: false, failed_conditions: [_], input: ^input}} =
               Condition.run(%{input: input, conditions: conditions, on_fail: :continue}, @ctx)
    end
  end
end
