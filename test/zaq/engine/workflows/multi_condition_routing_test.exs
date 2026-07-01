defmodule Zaq.Engine.Workflows.MultiConditionRoutingTest do
  @moduledoc """
  End-to-end routing + arithmetic test for a workflow that is **triggered by a
  dispatched event carrying a number** and fans out from its start node
  (`Router`) into three mutually exclusive range branches, each continuing into a
  chain of decrement-by-1 steps.

  Trigger + DAG:

      dispatch %Zaq.Event{name: :start, request: %{"number" => n}}
        └─ trigger "engine:start" fires the workflow, request → Router's input

      Router ──(number < 10)────────> A ──> Step 1 ──> Step 2
             ──(10 <= number < 20)──> B ──> Step 3 ──> Step 4
             ──(20 <= number < 30)──> C ──> Step 5 ──> Step 6 ──> Step 7

  `Router` (`RouteByRange`) passes the dispatched `number` through and classifies
  it into a `bucket` using the three range conditions above (edge conditions are
  single-op, so the range logic lives in the node and the edges route with `eq`
  on the emitted bucket). Every node in a branch (`A`, `Step 1`, …) is a
  `Decrement` action that lowers the running `number` by 1, so a branch of N
  decrement nodes lowers the number by exactly N:

      branch A (3 nodes):  5  → 2
      branch B (3 nodes): 15  → 12
      branch C (4 nodes): 25  → 21

  The final decremented `number` stored on the branch's last step proves the
  whole selected chain ran, while the other two branches are pruned. Runs through
  the real dispatch path:
    TriggerNode.fire → Workflows.create_and_start_run → WorkflowRunAgent.execute.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Event

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  # The event name whose dispatch is the sole trigger condition for this workflow.
  @trigger_event "engine:start"

  # `RouteByRange` is the start node (classifies the number into a bucket);
  # `Decrement` is every branch node/step (number - 1).
  @router_module "Zaq.Engine.Workflows.Test.RouteByRange"
  @decrement_module "Zaq.Engine.Workflows.Test.Decrement"

  # index mirrors branch depth: Router=0, {A,B,C}=1, first steps=2, ...
  defp scenario_nodes do
    [
      %{name: "Router", type: "action", module: @router_module, params: %{}, index: 0},
      # Branch A: A -> Step 1 -> Step 2
      %{name: "A", type: "action", module: @decrement_module, params: %{}, index: 1},
      %{name: "Step 1", type: "action", module: @decrement_module, params: %{}, index: 2},
      %{name: "Step 2", type: "action", module: @decrement_module, params: %{}, index: 3},
      # Branch B: B -> Step 3 -> Step 4
      %{name: "B", type: "action", module: @decrement_module, params: %{}, index: 1},
      %{name: "Step 3", type: "action", module: @decrement_module, params: %{}, index: 2},
      %{name: "Step 4", type: "action", module: @decrement_module, params: %{}, index: 3},
      # Branch C: C -> Step 5 -> Step 6 -> Step 7
      %{name: "C", type: "action", module: @decrement_module, params: %{}, index: 1},
      %{name: "Step 5", type: "action", module: @decrement_module, params: %{}, index: 2},
      %{name: "Step 6", type: "action", module: @decrement_module, params: %{}, index: 3},
      %{name: "Step 7", type: "action", module: @decrement_module, params: %{}, index: 4}
    ]
  end

  defp scenario_edges do
    [
      # Three mutually exclusive routes on the bucket Router derived from the
      # dispatched number's range.
      %{from: "Router", to: "A", condition: %{field: "bucket", op: :eq, value: "a"}},
      %{from: "Router", to: "B", condition: %{field: "bucket", op: :eq, value: "b"}},
      %{from: "Router", to: "C", condition: %{field: "bucket", op: :eq, value: "c"}},
      # Branch continuations (unconditional) — each carries the running number.
      %{from: "A", to: "Step 1"},
      %{from: "Step 1", to: "Step 2"},
      %{from: "B", to: "Step 3"},
      %{from: "Step 3", to: "Step 4"},
      %{from: "C", to: "Step 5"},
      %{from: "Step 5", to: "Step 6"},
      %{from: "Step 6", to: "Step 7"}
    ]
  end

  # Branch name -> the number to dispatch (inside the branch's range), the bucket
  # Router should derive, and the decrement chain (in order). The final number is
  # `number - length(steps)` since every step decrements by 1.
  @branches %{
    "A" => %{number: 5, bucket: "a", steps: ["A", "Step 1", "Step 2"]},
    "B" => %{number: 15, bucket: "b", steps: ["B", "Step 3", "Step 4"]},
    "C" => %{number: 25, bucket: "c", steps: ["C", "Step 5", "Step 6", "Step 7"]}
  }

  # Creates a workflow with the given DAG, binds it to the `start` trigger,
  # dispatches a real `start` event carrying `number` in its request payload
  # (synchronously through TriggerNode — the same entry point EventRegistry uses
  # when a matching event is broadcast via NodeRouter), and returns the run.
  defp fire_workflow(nodes, edges, number) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Multi Condition Routing #{System.unique_integer()}",
        status: "active",
        nodes: nodes,
        edges: edges
      })

    {:ok, trigger} = Workflows.create_trigger(%{event_name: @trigger_event, enabled: true})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

    event = %Event{
      request: %{"number" => number},
      next_hop: nil,
      name: :start,
      trace_id: Ecto.UUID.generate(),
      assigns: %{}
    }

    :ok = TriggerNode.fire(@trigger_event, event)

    workflow.id |> Workflows.list_runs() |> List.first()
  end

  defp dispatch(number), do: fire_workflow(scenario_nodes(), scenario_edges(), number)

  defp step_runs_by_name(run) do
    run.id
    |> Workflows.list_step_runs()
    |> Map.new(&{&1.step_name, &1})
  end

  describe "dispatched number routes by range and decrements through the branch" do
    for {branch, %{number: number, bucket: bucket, steps: steps}} <- @branches do
      final = number - length(steps)
      last_step = List.last(steps)

      test "number #{number} routes to branch #{branch} and decrements to #{final}" do
        run = dispatch(unquote(number))
        by_name = step_runs_by_name(run)

        assert run.status == "completed"

        # Every node in the selected branch ran.
        for name <- ["Router" | unquote(steps)] do
          assert by_name[name].status == "completed",
                 "expected #{name} to complete for number #{unquote(number)}"
        end

        # The final decremented number proves the whole chain ran once each.
        assert by_name[unquote(last_step)].results["number"] == unquote(final)
      end

      test "number #{number} prunes the two other branches" do
        run = dispatch(unquote(number))
        by_name = step_runs_by_name(run)

        other_steps =
          @branches
          |> Map.drop([unquote(branch)])
          |> Map.values()
          |> Enum.flat_map(& &1.steps)

        for name <- other_steps do
          refute Map.has_key?(by_name, name),
                 "expected #{name} to be pruned for number #{unquote(number)}"
        end
      end

      test "number #{number} reaches the Router start node unchanged" do
        run = dispatch(unquote(number))
        router = step_runs_by_name(run)["Router"]

        # Router echoes the dispatched number and derives the bucket, proving the
        # request payload arrived at the start node intact (string-keyed via JSONB).
        assert router, "Router StepRun must exist"
        assert router.results["number"] == unquote(number)
        assert router.results["bucket"] == unquote(bucket)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Two-branch threshold routing
  #
  #   Router ──(number >= 10)──> Step 1 ──> Step 3 ──> Step 4
  #          ──(number <  10)──> Step 2
  #
  # A single threshold splits Router into two mutually exclusive branches. The
  # "below" branch is one decrement (Step 2); the "at/above" branch is three
  # (Step 1 → Step 3 → Step 4). The final decremented number identifies the path.
  # ---------------------------------------------------------------------------
  @threshold 10

  defp two_branch_nodes do
    [
      %{name: "Router", type: "action", module: @router_module, params: %{}, index: 0},
      %{name: "Step 1", type: "action", module: @decrement_module, params: %{}, index: 1},
      %{name: "Step 2", type: "action", module: @decrement_module, params: %{}, index: 2},
      %{name: "Step 3", type: "action", module: @decrement_module, params: %{}, index: 3},
      %{name: "Step 4", type: "action", module: @decrement_module, params: %{}, index: 4}
    ]
  end

  defp two_branch_edges do
    [
      # "if less than x go to Step 2"; otherwise take the Step 1 → Step 3 → Step 4
      # chain. Both edges are conditional so exactly one branch runs.
      %{from: "Router", to: "Step 2", condition: %{field: "number", op: :lt, value: @threshold}},
      %{from: "Router", to: "Step 1", condition: %{field: "number", op: :gte, value: @threshold}},
      %{from: "Step 1", to: "Step 3"},
      %{from: "Step 3", to: "Step 4"}
    ]
  end

  describe "two-branch threshold routing decrements through the taken branch" do
    test "number below threshold takes the Step 2 branch (one decrement)" do
      run = fire_workflow(two_branch_nodes(), two_branch_edges(), 5)
      by_name = step_runs_by_name(run)

      assert run.status == "completed"
      assert by_name["Router"].status == "completed"
      assert by_name["Step 2"].status == "completed"
      # 5 - 1 = 4
      assert by_name["Step 2"].results["number"] == 4

      for name <- ["Step 1", "Step 3", "Step 4"] do
        refute Map.has_key?(by_name, name), "expected #{name} to be pruned below threshold"
      end
    end

    test "number at/above threshold takes the Step 1 → Step 3 → Step 4 branch (three decrements)" do
      run = fire_workflow(two_branch_nodes(), two_branch_edges(), 15)
      by_name = step_runs_by_name(run)

      assert run.status == "completed"

      for name <- ["Router", "Step 1", "Step 3", "Step 4"] do
        assert by_name[name].status == "completed",
               "expected #{name} to complete at/above threshold"
      end

      # 15 - 3 = 12
      assert by_name["Step 4"].results["number"] == 12

      refute Map.has_key?(by_name, "Step 2"), "expected Step 2 to be pruned at/above threshold"
    end
  end

  # ---------------------------------------------------------------------------
  # Loop back-edge: Step 4 -> Step 2 when number < x
  #
  #   Router -> Step 1 -> Step 3 -> Step 4
  #                          ^                | (number < x)
  #                          +----- Step 2 <--+
  #
  # The back-edge from "Step 4" to "Step 2" rejoins at "Step 3", forming a
  # cycle ("Step 3" -> "Step 4" -> "Step 2" -> "Step 3"). The engine is DAG-based,
  # so this must be rejected at workflow-creation time — never allowed to run.
  # ---------------------------------------------------------------------------
  defp loop_nodes do
    [
      %{name: "Router", type: "action", module: @router_module, params: %{}, index: 0},
      %{name: "Step 1", type: "action", module: @decrement_module, params: %{}, index: 1},
      %{name: "Step 2", type: "action", module: @decrement_module, params: %{}, index: 2},
      %{name: "Step 3", type: "action", module: @decrement_module, params: %{}, index: 3},
      %{name: "Step 4", type: "action", module: @decrement_module, params: %{}, index: 4}
    ]
  end

  defp loop_edges do
    [
      %{from: "Router", to: "Step 1"},
      %{from: "Step 1", to: "Step 3"},
      %{from: "Step 3", to: "Step 4"},
      # Back-edge from "Step 4" to "Step 2" when the running number is below the threshold.
      %{from: "Step 4", to: "Step 2", condition: %{field: "number", op: :lt, value: @threshold}},
      %{from: "Step 2", to: "Step 3"}
    ]
  end

  describe "loop back-edge from Step 4 to Step 2 is rejected before any run" do
    test "create_workflow refuses the cyclic DAG at save time" do
      params = %{
        name: "Loop Back Edge #{System.unique_integer()}",
        status: "active",
        nodes: loop_nodes(),
        edges: loop_edges()
      }

      # The acyclicity guard fires during creation, so the workflow is never
      # persisted and a run can never be started from it.
      assert {:error, %Ecto.Changeset{} = changeset} = Workflows.create_workflow(params)
      refute changeset.valid?

      assert {"invalid workflow composition", meta} = changeset.errors[:nodes]
      assert {:workflow_not_acyclic, cycle_nodes} = meta[:reason]
      assert Enum.sort(cycle_nodes) == ["Step 2", "Step 3", "Step 4"]
    end
  end

  describe "condition observability" do
    test "the two unmet conditions write skipped __edge guard rows" do
      run = dispatch(5)

      guard_names =
        run.id
        |> Workflows.list_step_runs()
        |> Enum.filter(&(String.contains?(&1.step_name, "__edge") and &1.status == "skipped"))
        |> Enum.map(& &1.step_name)

      assert "Router__to__B__edge" in guard_names
      assert "Router__to__C__edge" in guard_names
    end
  end
end
