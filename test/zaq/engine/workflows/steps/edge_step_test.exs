defmodule Zaq.Engine.Workflows.Steps.EdgeStepTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.Steps.EdgeStep

  # Helper to call EdgeStep.run directly.
  defp run(params), do: EdgeStep.run(params, %{})

  describe "no condition, no mapping (identity)" do
    test "passes fact through unchanged" do
      fact = %{name: "Sam", age: 30}

      params =
        Map.merge(%{__edge_condition__: nil, __edge_mapping__: %{}, __edge_name__: "e"}, fact)

      assert {:ok, ^fact} = run(params)
    end
  end

  describe "condition — passes" do
    test "returns fact when condition is true" do
      fact = %{gender: "male"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert {:ok, ^fact} = run(params)
    end
  end

  describe "condition — fails" do
    test "raises ConditionNotMet when condition is false" do
      fact = %{gender: "female"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{},
            __edge_name__: "b_to_c"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end
    end

    test "ConditionNotMet carries correct metadata" do
      fact = %{score: 3}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "score", "op" => "gt", "value" => 5},
            __edge_mapping__: %{},
            __edge_name__: "test_edge"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end

      try do
        run(params)
      rescue
        e in ConditionNotMet ->
          assert e.field == "score"
          assert e.op == :gt
          assert e.actual == 3
          assert e.expected == 5
          assert e.condition_name == "test_edge"
      end
    end
  end

  describe "mapping — key rename" do
    test "renames source key to target key" do
      fact = %{name: "Sam", age: 30, gender: "male"}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == "Sam"
      # Source key consumed — not passed through.
      refute Map.has_key?(result, :name)
      # Unmapped keys passed through.
      assert result[:age] == 30
      assert result[:gender] == "male"
    end

    test "multiple mappings rename all specified keys" do
      fact = %{a: 1, b: 2, c: 3}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{"x" => "a", "y" => "b"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:x] == 1
      assert result[:y] == 2
      refute Map.has_key?(result, :a)
      refute Map.has_key?(result, :b)
      assert result[:c] == 3
    end

    test "missing source key maps to nil" do
      fact = %{age: 30}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == nil
      assert result[:age] == 30
    end
  end

  describe "condition + mapping combined" do
    test "applies mapping when condition passes" do
      fact = %{gender: "male", name: "Sam"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == "Sam"
      refute Map.has_key?(result, :name)
    end

    test "raises ConditionNotMet before mapping when condition fails" do
      fact = %{gender: "female", name: "Sam"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
            __edge_mapping__: %{"person_name" => "name"},
            __edge_name__: "e"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end
    end
  end

  describe "mapping — atom-keyed mapping (lookup/to_key atom fallbacks)" do
    test "atom source and target keys in mapping are handled correctly" do
      fact = %{name: "Sam", age: 30}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{person_name: :name},
            __edge_name__: "e"
          },
          fact
        )

      {:ok, result} = run(params)
      assert result[:person_name] == "Sam"
      refute Map.has_key?(result, :name)
      assert result[:age] == 30
    end
  end

  describe "cascade-aware field lookup" do
    test "dotted path 'A.gender' resolves into __cascade__ (atom keys in step result)" do
      cascade = %{"A" => %{gender: "female"}}

      params = %{
        __edge_condition__: %{"field" => "A.gender", "op" => "eq", "value" => "female"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade
      }

      assert {:ok, _} = run(params)
    end

    test "dotted path 'A.gender' resolves into __cascade__ (string keys after JSONB round-trip)" do
      cascade = %{"A" => %{"gender" => "female"}}

      params =
        %{
          __edge_condition__: %{"field" => "A.gender", "op" => "eq", "value" => "female"},
          __edge_mapping__: %{},
          __edge_name__: "e"
        }
        |> Map.put("__cascade__", cascade)

      assert {:ok, _} = run(params)
    end

    test "dotted path where step name is absent in cascade → nil → condition false" do
      params = %{
        __edge_condition__: %{"field" => "missing.gender", "op" => "eq", "value" => "female"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: %{}
      }

      assert_raise ConditionNotMet, fn -> run(params) end
    end

    test "dotted path where __cascade__ is absent → nil → condition false" do
      params = %{
        __edge_condition__: %{"field" => "A.gender", "op" => "eq", "value" => "female"},
        __edge_mapping__: %{},
        __edge_name__: "e"
      }

      assert_raise ConditionNotMet, fn -> run(params) end
    end

    test "depth > 2 (A.b.c) returns nil and logs a warning" do
      import ExUnit.CaptureLog

      cascade = %{"A" => %{b: %{c: "deep"}}}

      params = %{
        __edge_condition__: %{"field" => "A.b.c", "op" => "eq", "value" => "deep"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade
      }

      log = capture_log(fn -> assert_raise ConditionNotMet, fn -> run(params) end end)
      assert log =~ "cascade"
    end

    test "__cascade__ is preserved in the output fact" do
      cascade = %{"A" => %{gender: "female"}}

      params = %{
        __edge_condition__: nil,
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade,
        value: "x"
      }

      assert {:ok, result} = run(params)
      assert result[:__cascade__] == cascade
    end

    test "plain field lookup is unaffected by cascade presence" do
      cascade = %{"A" => %{gender: "female"}}

      params = %{
        __edge_condition__: %{"field" => "status", "op" => "eq", "value" => "open"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade,
        status: "open"
      }

      assert {:ok, _} = run(params)
    end
  end

  describe "absent edge metadata keys" do
    test "works with no edge keys in params at all (identity)" do
      # EdgeStep strips known keys; if they are absent from params it still works.
      fact = %{foo: "bar"}
      assert {:ok, ^fact} = run(fact)
    end
  end

  describe "Step.Run trace — condition failure with run_id" do
    defp create_run_for_edge_step do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "EdgeStep Trace #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "a",
              type: "action",
              module: "Zaq.Engine.Workflows.Test.OkAction",
              params: %{},
              index: 0
            }
          ],
          edges: []
        })

      {:ok, run} =
        Workflows.create_run(wf, %{"request" => nil, "assigns" => %{}, "trace_id" => "t"})

      run
    end

    test "condition fails + run_id present → Step.Run written with status skipped" do
      run = create_run_for_edge_step()

      params = %{
        __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
        __edge_mapping__: %{},
        __edge_name__: "b_to_c_edge",
        run_id: run.id,
        gender: "female"
      }

      assert_raise ConditionNotMet, fn -> EdgeStep.run(params, %{}) end

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.step_name == "b_to_c_edge"
      assert step_run.step_index == 0
      assert step_run.status == "skipped"
      assert step_run.results["field"] == "gender"
      assert step_run.results["op"] == "eq"
      assert step_run.results["actual"] == "\"female\""
      assert step_run.results["expected"] == "\"male\""
    end

    test "condition fails + run_id absent → no Step.Run written, ConditionNotMet still raised" do
      run = create_run_for_edge_step()

      params = %{
        __edge_condition__: %{"field" => "score", "op" => "gt", "value" => 5},
        __edge_mapping__: %{},
        __edge_name__: "b_to_c_edge",
        score: 1
      }

      assert_raise ConditionNotMet, fn -> EdgeStep.run(params, %{}) end

      assert Workflows.list_step_runs(run.id) == []
    end

    test "condition passes + run_id present → Step.Run written with status completed" do
      run = create_run_for_edge_step()

      params = %{
        __edge_condition__: %{"field" => "gender", "op" => "eq", "value" => "male"},
        __edge_mapping__: %{},
        __edge_name__: "b_to_c_edge",
        __edge_source_index__: 2,
        run_id: run.id,
        gender: "male"
      }

      assert {:ok, _} = EdgeStep.run(params, %{})

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.step_name == "b_to_c_edge"
      assert step_run.step_index == 2
      assert step_run.status == "completed"
    end

    test "run_id is stripped from the output fact" do
      run = create_run_for_edge_step()

      fact = %{name: "Sam"}

      params =
        Map.merge(
          %{
            __edge_condition__: nil,
            __edge_mapping__: %{},
            __edge_name__: "e",
            run_id: run.id
          },
          fact
        )

      assert {:ok, result} = EdgeStep.run(params, %{})
      refute Map.has_key?(result, :run_id)
      assert result == fact
    end
  end
end
