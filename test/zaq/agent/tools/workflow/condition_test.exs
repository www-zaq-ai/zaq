defmodule Zaq.Agent.Tools.Workflow.ConditionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

      assert String.starts_with?(reason, "Condition not met:")
      assert reason =~ "active must equal true but was false"
      assert reason =~ "flagged must equal false but was true"
    end

    test "partial failure — only failing key is in the error string" do
      input = %{active: true, flagged: true}

      conditions = [
        %{"key" => "active", "value" => true},
        %{"key" => "flagged", "value" => false}
      ]

      assert {:error, reason} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)

      assert reason == "Condition not met: flagged must equal false but was true"
    end
  end

  describe "run/2 — clear error names every failed field (position example)" do
    test "two failing position conditions produce a self-explanatory message" do
      person = %{"name" => "John Doe", "age" => 24, "position" => "CTO"}

      conditions = [
        %{"key" => "position", "op" => "eq", "value" => "CFO"},
        %{"key" => "position", "op" => "eq", "value" => "CEO"}
      ]

      assert {:error, reason} = Condition.run(%{input: person, conditions: conditions}, @ctx)

      assert reason ==
               ~s(Condition not met: position must equal "CFO" but was "CTO"; ) <>
                 ~s(position must equal "CEO" but was "CTO")
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

      assert {:error, "Condition not met: email_state must be less than 4 but was 4"} =
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

    test "not_empty failure produces special message without actual value" do
      input = %{"name" => ""}
      conditions = [%{"key" => "name", "op" => "not_empty"}]

      assert {:error, "Condition not met: name must not be empty"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "empty failure includes rendered actual value" do
      input = %{"name" => "Alice"}
      conditions = [%{"key" => "name", "op" => "empty"}]

      assert {:error, ~s(Condition not met: name must be empty but was "Alice")} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "neq failure renders must not equal" do
      input = %{"status" => "active"}
      conditions = [%{"key" => "status", "op" => "neq", "value" => "active"}]

      assert {:error, ~s(Condition not met: status must not equal "active" but was "active")} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "gt failure renders must be greater than" do
      input = %{"score" => 5}
      conditions = [%{"key" => "score", "op" => "gt", "value" => 10}]

      assert {:error, "Condition not met: score must be greater than 10 but was 5"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "gte failure renders must be at least" do
      input = %{"score" => 4}
      conditions = [%{"key" => "score", "op" => "gte", "value" => 5}]

      assert {:error, "Condition not met: score must be at least 5 but was 4"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "lte failure renders must be at most" do
      input = %{"score" => 6}
      conditions = [%{"key" => "score", "op" => "lte", "value" => 5}]

      assert {:error, "Condition not met: score must be at most 5 but was 6"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "in failure renders must be one of" do
      input = %{"role" => "viewer"}
      conditions = [%{"key" => "role", "op" => "in", "value" => ["admin", "owner"]}]

      assert {:error,
              ~s(Condition not met: role must be one of ["admin", "owner"] but was "viewer")} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
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

      assert {:error, "Condition not met: email_state must be less than 0 but was 0"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "missing key without default fails the condition" do
      input = %{"active" => true}
      conditions = [%{"key" => "email_state", "op" => "lt", "value" => 4}]

      assert {:error, "Condition not met: email_state must be less than 4 but was empty"} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end
  end

  describe "run/2 — conditions fail with on_fail: :continue" do
    test "returns ok with passed: false and failed_conditions (no input passthrough)" do
      input = %{active: false}

      conditions = [%{"key" => "active", "value" => true}]

      # Routing mode omits `input` so it cannot clobber a downstream node's own param.
      assert {:ok, result} =
               Condition.run(%{input: input, conditions: conditions, on_fail: :continue}, @ctx)

      assert %{passed: false, failed_conditions: [_]} = result
      refute Map.has_key?(result, :input)
    end

    test "passing conditions in continue mode emit only passed: true" do
      input = %{active: true}
      conditions = [%{"key" => "active", "value" => true}]

      assert {:ok, result} =
               Condition.run(%{input: input, conditions: conditions, on_fail: :continue}, @ctx)

      assert result == %{passed: true}
    end
  end

  describe "run/2 — atom key in condition map" do
    test "fetch_value with atom key returns directly from atom-keyed input" do
      input = %{active: true}
      conditions = [%{key: :active, value: true}]

      assert {:ok, %{passed: true}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

    test "fetch_value with atom key falls back to string-keyed input" do
      input = %{"active" => true}
      conditions = [%{key: :active, value: true}]

      assert {:ok, %{passed: true}} =
               Condition.run(%{input: input, conditions: conditions}, @ctx)
    end

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
      assert {:error, "Condition not met: " <> _} =
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

  # ---------------------------------------------------------------------------
  # Blocker 1 (issue #508): a Condition as the FIRST node of a run triggered by
  # a dispatched event has no upstream node to produce an `:input` key. The
  # trigger payload seeds the fact at root, so the condition must evaluate
  # against the incoming fact at root instead of crashing on a missing `:input`.
  # ---------------------------------------------------------------------------
  describe "run/2 — first node off a trigger (root-fact contract)" do
    test "evaluates a root key when the trigger payload seeds the fact (no :input)" do
      params = %{
        "name" => "Jad",
        "age" => 32,
        "position" => "CTO",
        conditions: [%{"key" => "position", "op" => "eq", "value" => "CTO"}]
      }

      assert {:ok, %{passed: true}} = Condition.run(params, @ctx)
    end

    test "resolves a dotted path into a nested map at root" do
      params = %{
        profile: %{"position" => "CTO"},
        conditions: [%{"key" => "profile.position", "op" => "eq", "value" => "CTO"}]
      }

      assert {:ok, %{passed: true}} = Condition.run(params, @ctx)
    end

    test "explicit :input still wins (mid-DAG behaviour preserved)" do
      params = %{
        "position" => "CFO",
        input: %{"position" => "CTO"},
        conditions: [%{"key" => "position", "op" => "eq", "value" => "CTO"}]
      }

      assert {:ok, %{passed: true}} = Condition.run(params, @ctx)
    end

    # Additive guarantee: the root-fallback never weakens mid-DAG behaviour — when
    # `:input` is present it remains authoritative, regardless of any extra keys
    # sitting at the fact root (e.g. a persistent `start` namespace or cascade).
    property "explicit :input is authoritative regardless of arbitrary root noise" do
      check all(
              val <- StreamData.integer(),
              noise <-
                StreamData.map_of(
                  StreamData.string(:alphanumeric, min_length: 3),
                  StreamData.integer(),
                  max_length: 5
                )
            ) do
        base = %{
          input: %{"field" => val},
          conditions: [%{"key" => "field", "op" => "eq", "value" => val}]
        }

        # Plant a conflicting root value; :input must still win.
        noisy = noise |> Map.put("field", val + 1) |> Map.merge(base)

        assert {:ok, %{passed: true}} = Condition.run(base, @ctx)
        assert {:ok, %{passed: true}} = Condition.run(noisy, @ctx)
      end
    end
  end

  describe "run/2 — cascade-aware resolution (FactLookup parity with edges)" do
    test "resolves a node-qualified key from context.__cascade__" do
      ctx = %{__cascade__: %{"store_context" => %{record: %{id: 7}}}}
      conditions = [%{"key" => "store_context.record.id", "op" => "eq", "value" => 7}]

      assert {:ok, %{passed: true}} = Condition.run(%{conditions: conditions}, ctx)
    end

    test "resolves the persistent start.* namespace from the cascade" do
      ctx = %{__cascade__: %{start: %{"company context file" => "drive-123"}}}
      conditions = [%{"key" => "start.company context file", "op" => "not_empty"}]

      assert {:ok, %{passed: true}} = Condition.run(%{conditions: conditions}, ctx)
    end

    test "the original input is returned unchanged (cascade only augments the lookup view)" do
      input = %{"company context file" => ""}
      ctx = %{__cascade__: %{start: input}}
      conditions = [%{"key" => "company context file", "op" => "empty"}]

      assert {:ok, %{passed: true, input: ^input}} =
               Condition.run(%{input: input, conditions: conditions}, ctx)
    end
  end

  describe "run/2 — on_fail normalization (string forms from JSONB)" do
    test "string \"continue\" routes instead of halting" do
      input = %{active: false}
      conditions = [%{"key" => "active", "value" => true}]

      assert {:ok, %{passed: false, failed_conditions: [_]}} =
               Condition.run(%{input: input, conditions: conditions, on_fail: "continue"}, @ctx)
    end

    test "string \"halt\" stops the step" do
      input = %{active: false}
      conditions = [%{"key" => "active", "value" => true}]

      assert {:error, "Condition not met: active must equal true but was false"} =
               Condition.run(%{input: input, conditions: conditions, on_fail: "halt"}, @ctx)
    end

    test "an unrecognized on_fail value defaults to halt" do
      input = %{active: false}
      conditions = [%{"key" => "active", "value" => true}]

      assert {:error, "Condition not met: active must equal true but was false"} =
               Condition.run(%{input: input, conditions: conditions, on_fail: "bogus"}, @ctx)
    end
  end

  describe "run/2 — non-map input" do
    test "a scalar input falls back to condition defaults without raising" do
      params = %{
        input: "scalar-input",
        conditions: [%{"key" => "x", "op" => "eq", "value" => 1, "default" => 1}]
      }

      assert {:ok, %{passed: true, input: "scalar-input"}} = Condition.run(params, @ctx)
    end
  end

  describe "Action lifecycle hooks (contract defaults)" do
    test "on_success passes the result through and on_failure returns :ok" do
      assert {:ok, %{a: 1}} = Condition.on_success(%{a: 1}, %{})
      assert :ok = Condition.on_failure(:boom, %{})
    end
  end
end
