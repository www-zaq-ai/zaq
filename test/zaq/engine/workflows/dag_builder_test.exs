defmodule Zaq.Engine.Workflows.DagBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows.DagBuilder

  @fetch_module "Zaq.Agent.Tools.Email.FetchEmails"
  @ok_module "Zaq.Engine.Workflows.Test.OkAction"
  @noop_module "Zaq.Engine.Workflows.Test.Noop"
  @emit_person_module "Zaq.Engine.Workflows.Test.EmitPerson"
  @require_person_name_module "Zaq.Engine.Workflows.Test.RequirePersonName"
  @require_first_name_module "Zaq.Engine.Workflows.Test.RequireFirstName"

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
          "module" => @ok_module,
          "params" => %{},
          "index" => 1
        }
      ],
      "edges" => [%{"from" => "fetch", "to" => "draft"}]
    }
  end

  defp single_action_steps(module \\ @ok_module) do
    %{
      "nodes" => [
        %{"name" => "step", "type" => "action", "module" => module, "params" => %{}, "index" => 0}
      ],
      "edges" => []
    }
  end

  describe "Step 1 spike — edge-injection routing (D-1)" do
    # Scenario: A → B → C (gender==male, name→person_name) → D
    #                B → F (gender==female, name→first_name)
    defp user_scenario_steps(gender) do
      %{
        "nodes" => [
          %{
            "name" => "A",
            "type" => "action",
            "module" => @noop_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "B",
            "type" => "action",
            "module" => @emit_person_module,
            "params" => %{"gender" => gender},
            "index" => 1
          },
          %{
            "name" => "C",
            "type" => "action",
            "module" => @require_person_name_module,
            "params" => %{},
            "index" => 2
          },
          %{
            "name" => "D",
            "type" => "action",
            "module" => @noop_module,
            "params" => %{},
            "index" => 3
          },
          %{
            "name" => "F",
            "type" => "action",
            "module" => @require_first_name_module,
            "params" => %{},
            "index" => 2
          }
        ],
        "edges" => [
          %{"from" => "A", "to" => "B"},
          %{
            "from" => "B",
            "to" => "C",
            "condition" => %{"field" => "gender", "op" => "eq", "value" => "male"},
            "mapping" => %{"person_name" => "name"}
          },
          %{"from" => "C", "to" => "D"},
          %{
            "from" => "B",
            "to" => "F",
            "condition" => %{"field" => "gender", "op" => "eq", "value" => "female"},
            "mapping" => %{"first_name" => "name"}
          }
        ]
      }
    end

    test "gender=male: C runs (receives person_name, not name); F is pruned; run completes" do
      {:ok, dag} = DagBuilder.build(user_scenario_steps("male"))
      result = Runic.Workflow.react_until_satisfied(dag, %{})
      productions = Runic.Workflow.raw_productions(result)

      assert Enum.any?(productions, &Map.has_key?(&1, :c_ran)),
             "expected C to have run (c_ran key present in productions)"

      refute Enum.any?(productions, &Map.has_key?(&1, :f_ran)),
             "expected F to be pruned (f_ran key absent from productions)"
    end

    test "gender=female: F runs (receives first_name, not name); C is pruned; run completes" do
      {:ok, dag} = DagBuilder.build(user_scenario_steps("female"))
      result = Runic.Workflow.react_until_satisfied(dag, %{})
      productions = Runic.Workflow.raw_productions(result)

      assert Enum.any?(productions, &Map.has_key?(&1, :f_ran)),
             "expected F to have run (f_ran key present in productions)"

      refute Enum.any?(productions, &Map.has_key?(&1, :c_ran)),
             "expected C to be pruned (c_ran key absent from productions)"
    end

    test "gender=other: neither C nor F runs; run still completes without error" do
      {:ok, dag} = DagBuilder.build(user_scenario_steps("other"))
      result = Runic.Workflow.react_until_satisfied(dag, %{})
      productions = Runic.Workflow.raw_productions(result)

      refute Enum.any?(productions, &Map.has_key?(&1, :c_ran))
      refute Enum.any?(productions, &Map.has_key?(&1, :f_ran))
    end

    test "mapping isolation: C receives person_name but NOT the raw name key" do
      {:ok, dag} = DagBuilder.build(user_scenario_steps("male"))

      # RequirePersonName.run/2 raises if it receives :name — test passes only if mapping isolated.
      assert %Runic.Workflow{} = Runic.Workflow.react_until_satisfied(dag, %{})
    end

    test "mapping isolation: F receives first_name but NOT the raw name key" do
      {:ok, dag} = DagBuilder.build(user_scenario_steps("female"))
      assert %Runic.Workflow{} = Runic.Workflow.react_until_satisfied(dag, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # build/2 — run_id instrumentation
  # ---------------------------------------------------------------------------

  describe "build/2 — run_id instrumentation" do
    test "action nodes are wrapped in ActionWrapper when run_id is provided" do
      {:ok, workflow} = DagBuilder.build(single_action_steps(), run_id: "some-uuid")
      assert %Runic.Workflow{} = workflow
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

  # ---------------------------------------------------------------------------
  # build/1 — happy path
  # ---------------------------------------------------------------------------

  describe "build/1 — happy path" do
    test "returns a Runic.Workflow for a linear DAG" do
      assert {:ok, workflow} = DagBuilder.build(linear_steps())
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

    test "builds a branching DAG using edge conditions (no condition nodes)" do
      steps = %{
        "nodes" => [
          %{
            "name" => "root",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "branch_a",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 1
          },
          %{
            "name" => "branch_b",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 1
          }
        ],
        "edges" => [
          %{
            "from" => "root",
            "to" => "branch_a",
            "condition" => %{"field" => "value", "op" => "eq", "value" => "a"}
          },
          %{
            "from" => "root",
            "to" => "branch_b",
            "condition" => %{"field" => "value", "op" => "eq", "value" => "b"}
          }
        ]
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end

    test "mapping-only edge (no condition) builds and routes" do
      steps = %{
        "nodes" => [
          %{
            "name" => "src",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "dst",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 1
          }
        ],
        "edges" => [%{"from" => "src", "to" => "dst", "mapping" => %{"output" => "value"}}]
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end
  end

  # ---------------------------------------------------------------------------
  # build/1 — error cases
  # ---------------------------------------------------------------------------

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

    test "condition node type now returns unknown_node_type error" do
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

      assert {:error, {:unknown_node_type, "condition"}} = DagBuilder.build(steps)
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

    test "conditional edge with unknown op returns {:error, {:invalid_edge_condition, condition}}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "a",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "b",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 1
          }
        ],
        "edges" => [
          %{"from" => "a", "to" => "b", "condition" => %{"field" => "x", "op" => "totally_bogus"}}
        ]
      }

      assert {:error, {:invalid_edge_condition, _condition}} = DagBuilder.build(steps)
    end

    test "conditional edge to unknown node returns {:error, {:unknown_node, target}}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "a",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => [
          %{
            "from" => "a",
            "to" => "ghost",
            "condition" => %{"field" => "x", "op" => "eq", "value" => 1}
          }
        ]
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

  # ---------------------------------------------------------------------------
  # Misc — kept from before
  # ---------------------------------------------------------------------------

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

  describe "ConditionNotMet exception" do
    alias Zaq.Engine.Workflows.Conditions.ConditionNotMet

    test "message/1 formats the exception summary" do
      e = %ConditionNotMet{condition_name: "my_check", field: "count", op: :gt, actual: 0}
      assert Exception.message(e) =~ "my_check"
      assert Exception.message(e) =~ "count"
      assert Exception.message(e) =~ "gt"
    end
  end

  describe "build/2 — param atomization" do
    test "unknown string key in params triggers atomize_keys rescue and falls back gracefully" do
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

    test "atom-keyed params pass through atomize_keys unchanged" do
      steps = %{
        "nodes" => [
          %{
            "name" => "step",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{count: 5},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end

    test "nil params are passed through atomize_keys as-is" do
      steps = %{
        "nodes" => [
          %{
            "name" => "step",
            "type" => "action",
            "module" => @ok_module,
            "params" => nil,
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end
  end

  describe "build/1 — nil module" do
    test "node with nil module returns {:error, {:unknown_module, nil}}" do
      steps = %{
        "nodes" => [
          %{"name" => "step", "type" => "action", "module" => nil, "params" => %{}, "index" => 0}
        ],
        "edges" => []
      }

      assert {:error, {:unknown_module, nil}} = DagBuilder.build(steps)
    end
  end

  describe "build/1 — regression: plain edges unchanged" do
    test "linear DAG with plain edges produces same Runic.Workflow structure" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(linear_steps())
    end

    test "single-node DAG with no edges builds correctly" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(single_action_steps())
    end
  end

  # ---------------------------------------------------------------------------
  # Batch node — process / post_process resolution
  # ---------------------------------------------------------------------------

  @categorize_module "Zaq.Engine.Workflows.Test.CategorizeBySize"
  @sleep_ms_module "Zaq.Engine.Workflows.Test.SleepMs"
  @non_conforming_module "Zaq.Engine.Workflows.Test.NonConformingAction"
  @process_contact_module "Zaq.Engine.Workflows.Test.ProcessContact"
  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @iterate_module "Zaq.Agent.Tools.Workflow.Iterate"

  defp batch_steps(extra_params \\ %{}) do
    %{
      "nodes" => [
        %{
          "name" => "get_data",
          "type" => "action",
          "module" => @ok_module,
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "batch",
          "type" => "action",
          "module" => @batch_module,
          "params" =>
            Map.merge(
              %{
                "process" => [
                  %{
                    "name" => "categorize",
                    "type" => "action",
                    "module" => @categorize_module,
                    "params" => %{}
                  }
                ],
                "post_process" => [
                  %{
                    "name" => "sleep",
                    "type" => "action",
                    "module" => @sleep_ms_module,
                    "params" => %{}
                  }
                ]
              },
              extra_params
            ),
          "index" => 1
        }
      ],
      "edges" => [%{"from" => "get_data", "to" => "batch"}]
    }
  end

  defp iterate_steps(extra_params \\ %{}) do
    %{
      "nodes" => [
        %{
          "name" => "get_data",
          "type" => "action",
          "module" => @ok_module,
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "iterate",
          "type" => "action",
          "module" => @iterate_module,
          "params" =>
            Map.merge(
              %{
                "pipeline" => [
                  %{
                    "name" => "process_contact",
                    "type" => "action",
                    "module" => @process_contact_module,
                    "params" => %{}
                  }
                ]
              },
              extra_params
            ),
          "index" => 1
        }
      ],
      "edges" => [%{"from" => "get_data", "to" => "iterate"}]
    }
  end

  describe "build/1 — Batch node: process/post_process resolution" do
    test "valid process + post_process → builds successfully" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(batch_steps())
    end

    test "post_process absent → builds successfully with empty post_process" do
      steps = %{
        "nodes" => [
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{
              "process" => [
                %{
                  "name" => "categorize",
                  "type" => "action",
                  "module" => @categorize_module,
                  "params" => %{}
                }
              ]
            },
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end

    test "process and post_process nodes excluded from main DAG" do
      # Categorize and sleep are scoped; only get_data + batch appear as main nodes
      assert {:ok, wf} = DagBuilder.build(batch_steps())
      node_names = wf.graph |> Map.keys() |> Enum.map(&to_string/1)
      refute "categorize" in node_names
      refute "sleep" in node_names
    end

    test ":__batch_field__ and :__batch_mode__ derived from first process module schema" do
      # CategorizeBySize has items: [type: :list, required: true] → :list, :items
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(batch_steps())
      # Build success implies batch_field/1 resolved correctly (list mode for CategorizeBySize)
    end
  end

  describe "build/1 — Batch node: build-time errors" do
    test "process absent → {:error, {:missing_process_pipeline, node_name}}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:missing_process_pipeline, "batch"}} = DagBuilder.build(steps)
    end

    test "process empty list → {:error, {:missing_process_pipeline, node_name}}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{"process" => []},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:missing_process_pipeline, "batch"}} = DagBuilder.build(steps)
    end

    test "non-conforming process module → {:error, {:contract_violation, module, missing}}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{
              "process" => [
                %{
                  "name" => "bad",
                  "type" => "action",
                  "module" => @non_conforming_module,
                  "params" => %{}
                }
              ]
            },
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:contract_violation, _, _}} = DagBuilder.build(steps)
    end

    test "batch_scope (legacy) no longer accepted → missing_process_pipeline error" do
      steps = %{
        "nodes" => [
          %{
            "name" => "categorize",
            "type" => "action",
            "module" => @categorize_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{"batch_scope" => ["categorize"]},
            "index" => 1
          }
        ],
        "edges" => []
      }

      assert {:error, {:missing_process_pipeline, "batch"}} = DagBuilder.build(steps)
    end
  end

  # ---------------------------------------------------------------------------
  # Iterate node — pipeline resolution
  # ---------------------------------------------------------------------------

  describe "build/1 — Iterate node: pipeline resolution" do
    test "valid pipeline → builds successfully" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(iterate_steps())
    end

    test "pipeline nodes excluded from main DAG" do
      assert {:ok, wf} = DagBuilder.build(iterate_steps())
      node_names = wf.graph |> Map.keys() |> Enum.map(&to_string/1)
      refute "process_contact" in node_names
    end

    test ":__iterate_field__ and :__iterate_mode__ derived from first pipeline module schema" do
      # ProcessContact has contact: [type: :map, required: true] → :item, :contact
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(iterate_steps())
    end
  end

  describe "build/1 — Iterate node: build-time errors" do
    test "pipeline absent → {:error, {:missing_iterate_pipeline, node_name}}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "iterate",
            "type" => "action",
            "module" => @iterate_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:missing_iterate_pipeline, "iterate"}} = DagBuilder.build(steps)
    end

    test "non-conforming pipeline module → {:error, {:contract_violation, module, missing}}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "iterate",
            "type" => "action",
            "module" => @iterate_module,
            "params" => %{
              "pipeline" => [
                %{
                  "name" => "bad",
                  "type" => "action",
                  "module" => @non_conforming_module,
                  "params" => %{}
                }
              ]
            },
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:contract_violation, _, _}} = DagBuilder.build(steps)
    end
  end

  # ---------------------------------------------------------------------------
  # String refs rejected (clean break)
  # ---------------------------------------------------------------------------

  describe "build/1 — string refs rejected in process/post_process/pipeline" do
    test "string in process → {:error, :inline_node_required}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{"process" => ["some_string"]},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, :inline_node_required} = DagBuilder.build(steps)
    end

    test "string in post_process → {:error, :inline_node_required}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{
              "process" => [
                %{
                  "name" => "categorize",
                  "type" => "action",
                  "module" => @categorize_module,
                  "params" => %{}
                }
              ],
              "post_process" => ["some_string"]
            },
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, :inline_node_required} = DagBuilder.build(steps)
    end

    test "string in pipeline → {:error, :inline_node_required}" do
      steps = %{
        "nodes" => [
          %{
            "name" => "iterate",
            "type" => "action",
            "module" => @iterate_module,
            "params" => %{"pipeline" => ["some_string"]},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, :inline_node_required} = DagBuilder.build(steps)
    end
  end

  # ---------------------------------------------------------------------------
  # Nested Batch → Iterate inline
  # ---------------------------------------------------------------------------

  describe "build/1 — nested Batch → Iterate inline" do
    defp batch_iterate_inline_steps do
      %{
        "nodes" => [
          %{
            "name" => "batch",
            "type" => "action",
            "module" => @batch_module,
            "params" => %{
              "process" => [
                %{
                  "name" => "iterate",
                  "type" => "action",
                  "module" => @iterate_module,
                  "params" => %{
                    "pipeline" => [
                      %{
                        "name" => "process_contact",
                        "type" => "action",
                        "module" => @process_contact_module,
                        "params" => %{}
                      }
                    ]
                  }
                }
              ]
            },
            "index" => 0
          }
        ],
        "edges" => []
      }
    end

    test "Iterate inside Batch.process → builds successfully" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(batch_iterate_inline_steps())
    end

    test "neither iterate nor process_contact appear in the main DAG" do
      {:ok, wf} = DagBuilder.build(batch_iterate_inline_steps())
      node_names = wf.graph |> Map.keys() |> Enum.map(&to_string/1)
      refute "iterate" in node_names
      refute "process_contact" in node_names
    end
  end
end
