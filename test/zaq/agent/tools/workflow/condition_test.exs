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

  describe "run/2 — comparison operators via EdgeCondition" do
    test "lt passes when actual is less than value" do
      input = %{"email_state" => 3}
      conditions = [%{"key" => "email_state", "op" => "lt", "value" => 4}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "lt fails when actual equals value" do
      input = %{"email_state" => 4}
      conditions = [%{"key" => "email_state", "op" => "lt", "value" => 4}]

      assert {:error, "condition_failed:email_state"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "gt passes when actual is greater than value" do
      input = %{"score" => 10}
      conditions = [%{"key" => "score", "op" => "gt", "value" => 5}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "neq passes when actual differs from value" do
      input = %{"status" => "active"}
      conditions = [%{"key" => "status", "op" => "neq", "value" => "inactive"}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "in passes when actual is a member of value list" do
      input = %{"role" => "admin"}
      conditions = [%{"key" => "role", "op" => "in", "value" => ["admin", "owner"]}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "not_empty passes for non-blank value" do
      input = %{"name" => "Alice"}
      conditions = [%{"key" => "name", "op" => "not_empty"}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "empty passes for nil value" do
      input = %{"name" => nil}
      conditions = [%{"key" => "name", "op" => "empty"}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "defaults to eq when op is omitted" do
      input = %{"active" => true}
      conditions = [%{"key" => "active", "value" => true}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end
  end

  describe "run/2 — default value for missing keys" do
    test "uses default when key is absent and condition passes" do
      input = %{"active" => true}
      conditions = [%{"key" => "email_state", "op" => "lt", "value" => 4, "default" => 0}]

      assert {:ok, %{passed: true}} = Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "uses default when key is absent and condition fails" do
      input = %{"active" => true}
      conditions = [%{"key" => "email_state", "op" => "lt", "value" => 0, "default" => 0}]

      assert {:error, "condition_failed:email_state"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "missing key without default fails the condition" do
      input = %{"active" => true}
      conditions = [%{"key" => "email_state", "op" => "lt", "value" => 4}]

      assert {:error, "condition_failed:email_state"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
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

  describe "run/2 — atom key in condition map" do
    test "fetch_value with atom key falls back to string key in input" do
      # Condition key is an atom (e.g. from an atom-keyed condition map),
      # input is string-keyed — fetch_value/2 atom clause falls back to Atom.to_string(key).
      input = %{"active" => true}
      # Pass atom key via the condition map directly using atom key :key
      conditions = [%{key: "active", value: true}]

      assert {:ok, %{passed: true}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "fetch_value with atom key finds value directly in atom-keyed input" do
      # Both key and input are atom-keyed — the first Map.fetch hits directly.
      input = %{score: 10}
      conditions = [%{key: "score", value: 10}]

      assert {:ok, %{passed: true}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "to_op with atom op is a pass-through" do
      # op as an atom (not a string) exercises to_op/1 atom clause (line 127).
      input = %{"active" => true}
      conditions = [%{"key" => "active", "op" => :eq, "value" => true}]

      assert {:ok, %{passed: true}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end
  end

  describe "run/2 — ArgumentError rescue paths" do
    test "get_field rescues ArgumentError when string_key atom does not exist (line 124)" do
      # Use a key string that has never been interned as an atom in this VM session.
      # String.to_existing_atom/1 will raise ArgumentError, triggering the rescue nil path.
      # The condition key is also used in the failed_conditions list via Map.get fallback.
      unique_key = "never_seen_atom_xyz_#{System.unique_integer([:positive])}"
      input = %{}
      conditions = [%{"key" => unique_key, "value" => true}]

      # The condition will fail (key not found, no default) but must not raise
      assert {:error, "condition_failed:" <> _} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "fetch_value rescues ArgumentError when binary key atom does not exist (line 141)" do
      # Binary key where String.to_existing_atom raises because the atom was never created.
      # fetch_value/2 string-key clause rescues ArgumentError and returns :error,
      # triggering the default-value fallback path.
      unique_key = "fetch_value_rescue_xyz_#{System.unique_integer([:positive])}"
      input = %{}
      conditions = [%{"key" => unique_key, "value" => "anything", "default" => "anything"}]

      # With a default that matches value, the condition passes
      assert {:ok, %{passed: true}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end
  end
end
