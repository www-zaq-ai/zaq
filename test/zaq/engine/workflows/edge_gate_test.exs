defmodule Zaq.Engine.Workflows.EdgeGateTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Runic.Workflow
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.DagBuilder
  alias Zaq.Engine.Workflows.EdgeGate
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
    :ok
  end

  property "native predicates route exactly one branch regardless of edge order" do
    check all(x <- integer(-50..50), reverse? <- boolean()) do
      steps = branching_steps()
      steps = if reverse?, do: Map.update!(steps, "edges", &Enum.reverse/1), else: steps
      assert {:ok, dag} = DagBuilder.build(steps)
      assert length(Workflow.conditions(dag)) == 2

      finished = Workflow.react_until_satisfied(dag, %{x: x, name: "Sam"})
      outputs = Workflow.raw_productions(finished)

      assert Enum.any?(outputs, &Map.has_key?(&1, :c_ran)) == x > 3
      assert Enum.any?(outputs, &Map.has_key?(&1, :f_ran)) == x <= 3
      refute Workflow.is_runnable?(finished)
    end
  end

  test "false gates retain skip traces while the selected branch receives mapped input" do
    run = create_run(branching_steps(), %{x: 2, name: "Sam"})

    assert {:ok, finished} = WorkflowRunAgent.execute(run)
    assert finished.status == "completed"

    rows = Map.new(Workflows.list_step_runs(run.id), &{&1.step_name, &1})
    assert rows["start__to__b__edge"].status == "skipped"
    assert rows["start__to__c__edge"].status == "completed"
    assert rows["c"].status == "completed"
    assert rows["c"].results["first_name"] == "Sam"
    refute Map.has_key?(rows, "b")
  end

  test "a malformed native predicate records failure and never admits its action" do
    run = create_run(branching_steps(), %{x: 4, name: "Sam"})
    condition = %{"field" => "x", "op" => "not_an_operator", "value" => 3}

    # Bypass save-time validation to exercise a corrupted/prepared graph's runtime boundary.
    dag =
      Workflow.new(:invalid_gate)
      |> EdgeGate.add(condition, :gate, "start__to__b__edge", run.id, 0, validate: :off)
      |> Workflow.add(
        DagBuilder.build_action_node(Zaq.Engine.Workflows.Test.Noop, %{}, "b", 0, run.id),
        to: :gate,
        validate: :off
      )

    assert {:ok, finished} = WorkflowRunAgent.execute(%{run | prepared_dag: dag})
    assert finished.status == "failed"
    assert Workflows.get_run!(run.id).log_summary["failed_steps"] == ["start__to__b__edge"]

    assert [%{step_name: "start__to__b__edge", status: "failed"}] =
             Workflows.list_step_runs(run.id)
  end

  test "a mapping error after a true predicate leaves a failed edge trace" do
    steps = branching_steps()
    run = create_run(steps, %{x: 4, name: "Sam"})

    [edge | rest] = steps["edges"]
    malformed = Map.put(edge, "mapping", ["invalid_mapping_entry"])
    assert {:ok, dag} = DagBuilder.build(%{steps | "edges" => [malformed | rest]}, run_id: run.id)

    assert {:ok, finished} = WorkflowRunAgent.execute(%{run | prepared_dag: dag})
    assert finished.status == "failed"
    edge_row = Workflows.get_step_run_by_name(run.id, "start__to__b__edge")
    assert edge_row.status == "failed"
    refute Workflows.get_step_run_by_name(run.id, "b")
  end

  test "run identifiers are excluded from native predicate identity" do
    assert {:ok, first} = DagBuilder.build(branching_steps(), run_id: Ecto.UUID.generate())
    assert {:ok, second} = DagBuilder.build(branching_steps(), run_id: Ecto.UUID.generate())

    identities = fn dag -> Map.new(Workflow.conditions(dag), &{&1.name, &1.hash}) end
    assert identities.(first) == identities.(second)
  end

  test "a conditional root edge matches the input field of a scalar trigger" do
    edges = [
      %{
        "from" => "start",
        "to" => "done",
        "condition" => %{"field" => "input", "op" => "eq", "value" => "go"}
      }
    ]

    steps = %{
      "nodes" => [
        %{
          "name" => "done",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.Noop",
          "params" => %{},
          "index" => 0
        }
      ],
      "edges" => edges
    }

    run = create_run(steps, "go")

    assert {:ok, finished} = WorkflowRunAgent.execute(run)
    assert finished.status == "completed"
    assert Workflows.get_run!(run.id).status == "completed"

    rows = Map.new(Workflows.list_step_runs(run.id), &{&1.step_name, &1})
    assert rows["start__to__done__edge"].status == "completed"
    assert rows["done"].status == "completed"
    assert rows["done"].results["noop"] == true
  end

  defp branching_steps do
    %{
      "nodes" => [
        %{
          "name" => "b",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.RequirePersonName",
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "c",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.RequireFirstName",
          "params" => %{},
          "index" => 1
        }
      ],
      "edges" => [
        %{
          "from" => "start",
          "to" => "b",
          "condition" => %{"field" => "x", "op" => "gt", "value" => 3},
          "mapping" => %{"person_name" => "name"}
        },
        %{
          "from" => "start",
          "to" => "c",
          "condition" => %{"field" => "x", "op" => "lte", "value" => 3},
          "mapping" => %{"first_name" => "name"}
        }
      ]
    }
  end

  defp create_run(steps, input) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Native gate #{System.unique_integer()}",
        status: "active",
        nodes: steps["nodes"],
        edges: steps["edges"]
      })

    {:ok, run} =
      Workflows.create_run(workflow, %{
        "assigns" => %{"trigger_type" => "manual", "input" => input},
        "trace_id" => Ecto.UUID.generate()
      })

    run
  end
end
