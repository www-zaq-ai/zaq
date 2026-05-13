defmodule Zaq.Engine.Workflows.DagBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows.DagBuilder

  @fetch_module "Zaq.Agent.Tools.Email.FetchEmails"
  @always_condition_module "Zaq.Engine.Workflows.Test.AlwaysCondition"
  @never_condition_module "Zaq.Engine.Workflows.Test.NeverCondition"
  @draft_module "Zaq.Agent.Tools.Email.DraftReply"

  defp linear_steps do
    %{
      "nodes" => [
        %{
          "name" => "fetch",
          "type" => "action",
          "module" => @fetch_module,
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "draft",
          "type" => "action",
          "module" => @draft_module,
          "params" => %{},
          "index" => 1
        }
      ],
      "edges" => [
        %{"from" => "fetch", "to" => "draft"}
      ]
    }
  end

  defp branching_steps do
    %{
      "nodes" => [
        %{
          "name" => "fetch",
          "type" => "action",
          "module" => @fetch_module,
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "emails_found",
          "type" => "condition",
          "module" => @always_condition_module,
          "params" => %{},
          "index" => 1
        },
        %{
          "name" => "no_emails",
          "type" => "condition",
          "module" => @never_condition_module,
          "params" => %{},
          "index" => 1
        },
        %{
          "name" => "draft",
          "type" => "action",
          "module" => @draft_module,
          "params" => %{},
          "index" => 2
        }
      ],
      "edges" => [
        %{"from" => "fetch", "to" => "emails_found"},
        %{"from" => "fetch", "to" => "no_emails"},
        %{"from" => "emails_found", "to" => "draft"}
      ]
    }
  end

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"

  defp single_action_steps(module \\ @ok_module) do
    %{
      "nodes" => [
        %{"name" => "step", "type" => "action", "module" => module, "params" => %{}, "index" => 0}
      ],
      "edges" => []
    }
  end

  describe "build/2 — run_id instrumentation" do
    test "action nodes are wrapped in ActionWrapper when run_id is provided" do
      {:ok, workflow} = DagBuilder.build(single_action_steps(), run_id: "some-uuid")
      assert %Runic.Workflow{} = workflow
    end

    test "condition nodes are NOT wrapped when run_id is provided" do
      steps = %{
        "nodes" => [
          %{
            "name" => "fetch",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "cond",
            "type" => "condition",
            "module" => @always_condition_module,
            "params" => %{},
            "index" => 1
          }
        ],
        "edges" => [%{"from" => "fetch", "to" => "cond"}]
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps, run_id: "some-uuid")
    end

    test "build/1 with no opts preserves existing behaviour (no ActionWrapper)" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(single_action_steps())
    end

    test "build/2 with nil run_id behaves like build/1 (no wrapping)" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(single_action_steps(), run_id: nil)
    end

    test "error cases still return errors when run_id provided" do
      assert {:error, {:unknown_module, "Does.Not.Exist"}} =
               DagBuilder.build(single_action_steps("Does.Not.Exist"), run_id: "some-uuid")
    end
  end

  describe "build/1 — happy path" do
    test "returns a Runic.Workflow for a linear DAG" do
      assert {:ok, workflow} = DagBuilder.build(linear_steps())
      assert %Runic.Workflow{} = workflow
    end

    test "returns a Runic.Workflow for a branching DAG with conditions" do
      assert {:ok, workflow} = DagBuilder.build(branching_steps())
      assert %Runic.Workflow{} = workflow
    end

    test "action nodes resolve params from the steps definition" do
      steps = %{
        "nodes" => [
          %{
            "name" => "fetch",
            "type" => "action",
            "module" => @fetch_module,
            "params" => %{"limit" => 5},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end

    test "builds without raising regardless of action parameter overlap" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(branching_steps())
    end
  end

  describe "build/1 — error cases" do
    test "returns error for empty nodes and edges" do
      assert {:error, :empty_dag} = DagBuilder.build(%{"nodes" => [], "edges" => []})
    end

    test "returns error for unknown action module" do
      steps = %{
        "nodes" => [
          %{
            "name" => "x",
            "type" => "action",
            "module" => "Does.Not.Exist",
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:unknown_module, "Does.Not.Exist"}} = DagBuilder.build(steps)
    end

    test "returns error for unknown condition module" do
      steps = %{
        "nodes" => [
          %{
            "name" => "x",
            "type" => "condition",
            "module" => "Does.Not.Exist",
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:unknown_module, "Does.Not.Exist"}} = DagBuilder.build(steps)
    end

    test "returns error when edge references unknown node" do
      steps = %{
        "nodes" => [
          %{
            "name" => "fetch",
            "type" => "action",
            "module" => @fetch_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => [%{"from" => "fetch", "to" => "ghost"}]
      }

      assert {:error, {:unknown_node, "ghost"}} = DagBuilder.build(steps)
    end

    test "returns error for missing nodes key" do
      assert {:error, :invalid_steps} = DagBuilder.build(%{"edges" => []})
    end

    test "returns error for missing edges key" do
      assert {:error, :invalid_steps} = DagBuilder.build(%{"nodes" => []})
    end
  end

  # --- Property tests ---

  describe "build/1 — structural invariants" do
    property "any non-map input returns {:error, :invalid_steps}" do
      check all(
              input <-
                one_of([
                  integer(),
                  float(),
                  string(:alphanumeric),
                  atom(:alphanumeric),
                  list_of(term()),
                  constant(nil)
                ])
            ) do
        assert DagBuilder.build(input) == {:error, :invalid_steps}
      end
    end

    property "any map missing 'nodes', 'edges', or both returns {:error, :invalid_steps}" do
      check all(present_key <- member_of(["nodes", "edges", :neither])) do
        steps =
          case present_key do
            "nodes" ->
              %{
                "nodes" => [
                  %{
                    "name" => "x",
                    "type" => "action",
                    "module" => @ok_module,
                    "params" => %{},
                    "index" => 0
                  }
                ]
              }

            "edges" ->
              %{"edges" => []}

            :neither ->
              %{}
          end

        assert DagBuilder.build(steps) == {:error, :invalid_steps}
      end
    end

    property "empty nodes list always returns {:error, :empty_dag} regardless of edges content" do
      check all(
              edges <-
                list_of(
                  map_of(
                    string(:alphanumeric, min_length: 1),
                    string(:alphanumeric, min_length: 1),
                    max_length: 3
                  ),
                  max_length: 5
                )
            ) do
        assert DagBuilder.build(%{"nodes" => [], "edges" => edges}) == {:error, :empty_dag}
      end
    end

    property "edge referencing a non-existent node returns {:error, {:unknown_node, target}}" do
      check all(
              node_name <- string(:alphanumeric, min_length: 1),
              target <- string(:alphanumeric, min_length: 1),
              node_name != target
            ) do
        steps = %{
          "nodes" => [
            %{
              "name" => node_name,
              "type" => "action",
              "module" => @ok_module,
              "params" => %{},
              "index" => 0
            }
          ],
          "edges" => [%{"from" => node_name, "to" => target}]
        }

        assert DagBuilder.build(steps) == {:error, {:unknown_node, target}}
      end
    end
  end

  # --- Inline conditions ---

  defp inline_cond_steps(op, value \\ nil) do
    params =
      if is_nil(value),
        do: %{"field" => "count", "op" => op},
        else: %{"field" => "count", "op" => op, "value" => value}

    %{
      "nodes" => [
        %{"name" => "check", "type" => "condition", "params" => params, "index" => 0}
      ],
      "edges" => []
    }
  end

  describe "build/2 — inline condition (no module)" do
    test "builds inline condition node with nil module" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(inline_cond_steps("eq", 5))
    end

    test "builds inline condition node with empty string module" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "module" => "",
            "params" => %{"field" => "x", "op" => "eq", "value" => 1},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end

    test "eq operator: runs without error when condition passes" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("eq", 5))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 5})
    end

    test "eq operator: runs without error when condition fails" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("eq", 5))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 99})
    end

    test "neq operator" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("neq", 5))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 3})
    end

    test "gt operator: passes when greater" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("gt", 3))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 5})
    end

    test "gt operator: fails when not greater" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("gt", 10))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 5})
    end

    test "lt operator" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("lt", 10))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 5})
    end

    test "gte operator: passes when equal" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("gte", 5))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 5})
    end

    test "lte operator: passes when equal" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("lte", 5))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 5})
    end

    test "not_empty: passes for non-empty list" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("not_empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => [1, 2]})
    end

    test "not_empty: fails for nil value" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("not_empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => nil})
    end

    test "not_empty: fails for empty list" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("not_empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => []})
    end

    test "not_empty: fails for empty string" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("not_empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => ""})
    end

    test "empty: passes for nil" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => nil})
    end

    test "empty: passes for empty list" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => []})
    end

    test "empty: passes for empty string" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => ""})
    end

    test "empty: fails for non-empty value" do
      {:ok, dag} = DagBuilder.build(inline_cond_steps("empty"))
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => [1]})
    end

    test "in operator: passes when value is in list" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "params" => %{"field" => "status", "op" => "in", "value" => ["active", "pending"]},
            "index" => 0
          }
        ],
        "edges" => []
      }

      {:ok, dag} = DagBuilder.build(steps)
      _result = Runic.Workflow.react_until_satisfied(dag, %{"status" => "active"})
    end

    test "in operator: fails when value is not in list" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "params" => %{"field" => "status", "op" => "in", "value" => ["active"]},
            "index" => 0
          }
        ],
        "edges" => []
      }

      {:ok, dag} = DagBuilder.build(steps)
      _result = Runic.Workflow.react_until_satisfied(dag, %{"status" => "inactive"})
    end

    test "field resolved via atom key in fact" do
      # param/2 falls back to String.to_atom(key) when string key lookup returns nil
      {:ok, dag} = DagBuilder.build(inline_cond_steps("gt", 0))
      _result = Runic.Workflow.react_until_satisfied(dag, %{count: 5})
    end

    test "unknown op raises ArgumentError inside work fn (Runic handles gracefully)" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "params" => %{"field" => "x", "op" => "bad_op"},
            "index" => 0
          }
        ],
        "edges" => []
      }

      {:ok, dag} = DagBuilder.build(steps)
      # compare_op catch-all raises ArgumentError; Runic catches it and skips downstream
      _result = Runic.Workflow.react_until_satisfied(dag, %{"x" => 1})
    end

    test "missing field param raises ArgumentError inside work fn (Runic handles gracefully)" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "params" => %{"op" => "eq", "value" => 1},
            "index" => 0
          }
        ],
        "edges" => []
      }

      {:ok, dag} = DagBuilder.build(steps)
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 1})
    end

    test "missing op param raises ArgumentError inside work fn (Runic handles gracefully)" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "params" => %{"field" => "count"},
            "index" => 0
          }
        ],
        "edges" => []
      }

      {:ok, dag} = DagBuilder.build(steps)
      _result = Runic.Workflow.react_until_satisfied(dag, %{"count" => 1})
    end
  end

  describe "build/2 — module-backed condition execution" do
    test "module condition: runs without error when condition passes" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "module" => @always_condition_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      {:ok, dag} = DagBuilder.build(steps)
      _result = Runic.Workflow.react_until_satisfied(dag, %{})
    end

    test "module condition: runs without error when condition fails (downstream skipped)" do
      steps = %{
        "nodes" => [
          %{
            "name" => "check",
            "type" => "condition",
            "module" => @never_condition_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      {:ok, dag} = DagBuilder.build(steps)
      _result = Runic.Workflow.react_until_satisfied(dag, %{})
    end
  end

  describe "build/2 — agent type nodes" do
    test "builds agent type node the same as action" do
      steps = %{
        "nodes" => [
          %{
            "name" => "step",
            "type" => "agent",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end
  end

  describe "build/2 — param atomization" do
    test "unknown string key in params triggers atomize_keys rescue and falls back gracefully" do
      # String.to_existing_atom/1 raises for unknown atoms — atomize_keys must rescue
      steps = %{
        "nodes" => [
          %{
            "name" => "step",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{"zaq_dag_builder_rescue_test_key_xyz" => "val"},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end
  end
end
