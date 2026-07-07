defmodule Zaq.Engine.Workflows.Steps.EdgeStepTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.Steps.EdgeStep

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

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

    test "depth-3 path 'A.b.c' resolves into nested map (atom keys)" do
      cascade = %{"A" => %{b: %{c: "deep"}}}

      params = %{
        __edge_condition__: %{"field" => "A.b.c", "op" => "eq", "value" => "deep"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade
      }

      assert {:ok, _} = run(params)
    end

    test "depth-3 path resolves string-keyed nested map (JSONB round-trip)" do
      cascade = %{"ensure_person" => %{"row" => %{"row_index" => 5}}}

      params = %{
        __edge_condition__: %{
          "field" => "ensure_person.row.row_index",
          "op" => "eq",
          "value" => 5
        },
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade
      }

      assert {:ok, _} = run(params)
    end

    test "depth-3 path in mapping injects nested value as top-level key" do
      cascade = %{"ensure_person" => %{row: %{"row_index" => 7}}}

      params = %{
        __edge_condition__: nil,
        __edge_mapping__: %{"row_index" => "ensure_person.row.row_index"},
        __edge_name__: "e",
        __cascade__: cascade
      }

      assert {:ok, result} = run(params)
      assert result[:row_index] == 7
    end

    test "depth-3 path where intermediate map is absent returns nil" do
      cascade = %{"A" => %{other: "field"}}

      params = %{
        __edge_condition__: %{"field" => "A.b.c", "op" => "eq", "value" => "deep"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade
      }

      assert_raise ConditionNotMet, fn -> run(params) end
    end

    test "depth-3 path where intermediate value is a scalar returns nil" do
      cascade = %{"A" => %{b: "not_a_map"}}

      params = %{
        __edge_condition__: %{"field" => "A.b.c", "op" => "eq", "value" => "deep"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: cascade
      }

      assert_raise ConditionNotMet, fn -> run(params) end
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

    test "dotted path where cascade entry is a scalar (non-map) → nil → condition false (line 182)" do
      # cascade["A"] exists but is a string, not a map — hits `_ -> nil` in lookup_cascade (line 182)
      params = %{
        __edge_condition__: %{"field" => "A.gender", "op" => "eq", "value" => "female"},
        __edge_mapping__: %{},
        __edge_name__: "e",
        __cascade__: %{"A" => "not_a_map"}
      }

      assert_raise ConditionNotMet, fn -> run(params) end
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

  describe "normalize_value — nested map values" do
    test "atom-keyed nested map passes through with atom keys intact (line 138)" do
      # The mapped value is a nested map with atom keys → hits the {k, v} clause
      # for atom keys in normalize_value/1 (line 138 in edge_step.ex)
      fact = %{profile: %{city: "Paris", age: 30}}

      params =
        Map.merge(
          %{__edge_condition__: nil, __edge_mapping__: %{location: :profile}, __edge_name__: "e"},
          fact
        )

      {:ok, result} = run(params)
      assert result[:location] == %{city: "Paris", age: 30}
      refute Map.has_key?(result, :profile)
    end

    test "string key not yet an atom is kept as string in normalize_value (line 147)" do
      # "zaq_novel_nonexistent_key_9x7" has never been used as an atom in this runtime,
      # so String.to_existing_atom/1 raises ArgumentError → key stays as string (line 147)
      novel_key = "zaq_novel_nonexistent_key_9x7"
      fact = %{data: %{novel_key => "val"}}

      params =
        Map.merge(
          %{__edge_condition__: nil, __edge_mapping__: %{result: :data}, __edge_name__: "e"},
          fact
        )

      {:ok, output} = run(params)
      assert output[:result][novel_key] == "val"
    end
  end

  describe "absent edge metadata keys" do
    test "works with no edge keys in params at all (identity)" do
      # EdgeStep strips known keys; if they are absent from params it still works.
      fact = %{foo: "bar"}
      assert {:ok, ^fact} = run(fact)
    end
  end

  # ---------------------------------------------------------------------------
  # Date conditions through the runtime routing seam: proves `edge_step.ex` reads
  # `"type"` from the stored condition and threads it into `EdgeCondition.evaluate/4`,
  # so a branch is kept/pruned by *chronological* comparison — not `Kernel` term
  # order. EdgeStep does not inject a clock, so sentinel/relative values resolve
  # against the real clock; tests stay deterministic by using unambiguous instants.
  # ---------------------------------------------------------------------------
  describe "condition — date type (routing seam)" do
    test "keeps the branch when a date field is chronologically before the bound" do
      fact = %{due_date: "2026-07-01"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{
              "field" => "due_date",
              "type" => "date",
              "op" => "lt",
              "value" => "2026-07-10"
            },
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert {:ok, ^fact} = run(params)
    end

    test "prunes the branch when a date field is not before the bound" do
      fact = %{due_date: "2026-07-10"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{
              "field" => "due_date",
              "type" => "date",
              "op" => "lt",
              "value" => "2026-07-01"
            },
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end
    end

    test "term-order regression: %Date{} branch prunes by chronology, not map-key order" do
      # ~D[2020-12-31] is chronologically BEFORE ~D[2021-01-01], so `gt` is false and
      # the branch must prune. The legacy Kernel path would compare the structs by
      # map key (day 31 > day 1) and *wrongly keep* the branch — this asserts the fix
      # reaches all the way through EdgeStep.
      fact = %{created: ~D[2020-12-31]}

      params =
        Map.merge(
          %{
            __edge_condition__: %{
              "field" => "created",
              "type" => "date",
              "op" => "gt",
              "value" => "2021-01-01"
            },
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end
    end

    test "relative map ('older than 7 days') keeps the branch for a far-past datetime" do
      # A fixed far-past instant is unambiguously older than now-7d regardless of the
      # wall clock, so this stays deterministic without a clock override.
      fact = %{last_sent_at: "2000-01-01T00:00:00Z"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{
              "field" => "last_sent_at",
              "type" => "datetime",
              "op" => "lt",
              "value" => %{"from" => "now", "days" => -7}
            },
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert {:ok, ^fact} = run(params)
    end

    test "atom-keyed :type on the stored condition also threads through" do
      # `edge_step.ex` reads `condition["type"] || condition[:type]` — cover the atom
      # branch (an in-memory, non-JSONB condition map).
      fact = %{created: ~D[2026-07-01]}

      params =
        Map.merge(
          %{
            __edge_condition__: %{field: "created", type: "date", op: :lt, value: "2026-07-10"},
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert {:ok, ^fact} = run(params)
    end

    test "an unresolvable date operand prunes the branch (never crashes)" do
      fact = %{due_date: "not-a-date"}

      params =
        Map.merge(
          %{
            __edge_condition__: %{
              "field" => "due_date",
              "type" => "date",
              "op" => "lt",
              "value" => "2026-07-10"
            },
            __edge_mapping__: %{},
            __edge_name__: "e"
          },
          fact
        )

      assert_raise ConditionNotMet, fn -> run(params) end
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

    test "date condition fails + run_id present → skipped Step.Run records the date operands" do
      run = create_run_for_edge_step()

      params = %{
        __edge_condition__: %{
          "field" => "due_date",
          "type" => "date",
          "op" => "lt",
          "value" => "2026-07-01"
        },
        __edge_mapping__: %{},
        __edge_name__: "overdue_edge",
        run_id: run.id,
        due_date: "2026-07-10"
      }

      assert_raise ConditionNotMet, fn -> EdgeStep.run(params, %{}) end

      [step_run] = Workflows.list_step_runs(run.id)
      assert step_run.step_name == "overdue_edge"
      assert step_run.status == "skipped"
      assert step_run.results["field"] == "due_date"
      assert step_run.results["op"] == "lt"
      assert step_run.results["actual"] == "\"2026-07-10\""
      assert step_run.results["expected"] == "\"2026-07-01\""
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
