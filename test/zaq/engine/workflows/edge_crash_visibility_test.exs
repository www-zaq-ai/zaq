defmodule Zaq.Engine.Workflows.EdgeCrashVisibilityTest do
  @moduledoc """
  Integration coverage for Step 2 of the EdgeStep crash-visibility fix: an
  unexpected raise inside `Steps.EdgeStep.run/1` (condition-check or mapping)
  must fail the run visibly — a `"failed"` `Step.Run` row for the edge, the run
  finalized `"failed"` (not a silent `"incomplete"`), and a `run.failed` event
  dispatched — instead of Runic silently pruning the downstream subgraph.

  Crash trigger: an edge condition with an unknown `op` (`"no_such_op"`), the
  same trigger `edge_step_test.exs` uses at the unit level — independent of the
  Step-1 struct-normalization bug, per the plan's Decisions Log.

  ## Why this hand-assembles the Runic graph instead of going through
  `Workflows.create_workflow/1` + `Workflows.create_run/2`

  Both `Step.Edge.changeset/2` (save time) AND `DagBuilder.build/2`
  (unconditionally, on every `create_run/2` and resume) validate edge
  conditions via `EdgeCondition.changeset/1` — so an unknown `op` can never
  reach a `prepared_dag` through either public path; `create_run/2` would
  return a run with `prepared_dag: nil` and `execute/1` would short-circuit
  with `{:error, :missing_prepared_dag}` before ever reaching `EdgeStep`. That
  is a real, load-bearing second line of defense, not a gap.

  This test proves the layer *underneath* that defense: if a condition ever
  did reach a run's live graph — a future validation gap, corrupted/legacy
  `steps_snapshot` data, or any other unexpected raise inside `EdgeStep.run/1`
  — `WorkflowRunAgent.execute/1` still fails the run visibly instead of
  silently finalizing `"incomplete"`. It hand-assembles a `prepared_dag` with
  `DagBuilder.build_action_node/5` (the same public helper `DagBuilder` uses
  for real nodes) and a guard `ActionNode` wired exactly like
  `DagBuilder`'s private `build_edge_step_node/5`, bypassing only
  `validate_edges/2` — everything else is the real node/edge wiring.
  """
  use Zaq.DataCase, async: false

  alias Jido.Runic.ActionNode
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.DagBuilder
  alias Zaq.Engine.Workflows.Steps.EdgeStep
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @ok_module Zaq.Engine.Workflows.Test.OkAction
  @noop_module Zaq.Engine.Workflows.Test.Noop

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp crashing_run do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Edge Crash #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{name: "a", type: "action", module: to_string(@ok_module), params: %{}, index: 0},
          %{name: "b", type: "action", module: to_string(@noop_module), params: %{}, index: 1}
        ],
        # Valid at save/build time (`op: "eq"`) — this workflow's own prepared_dag
        # is discarded in favor of `build_prepared_dag/1` below, which injects the
        # unknown-op condition directly into the hand-assembled graph.
        edges: [%{from: "a", to: "b", condition: %{field: "value", op: :eq, value: "done"}}]
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    %{run | prepared_dag: build_prepared_dag(run.id)}
  end

  # Mirrors `DagBuilder`'s real node/edge wiring for `a -> b` with a guard, except
  # the guard's `__edge_condition__` carries the unknown-op condition that
  # `DagBuilder.build/2` would reject at `validate_edges/2` — see moduledoc.
  defp build_prepared_dag(run_id) do
    a_node = DagBuilder.build_action_node(@ok_module, %{}, "a", 0, run_id)
    b_node = DagBuilder.build_action_node(@noop_module, %{}, "b", 1, run_id)

    guard_params = %{
      __edge_condition__: %{"field" => "value", "op" => "no_such_op", "value" => "x"},
      __edge_mapping__: %{},
      __edge_name__: "a__to__b__edge",
      __edge_source_index__: 0,
      run_id: run_id
    }

    guard_node =
      ActionNode.new(EdgeStep, guard_params,
        name: DagBuilder.node_atom("a__to__b__edge"),
        max_retries: 0
      )

    Runic.Workflow.new(:workflow)
    |> Runic.Workflow.add(a_node)
    |> Runic.Workflow.add(guard_node, to: DagBuilder.node_atom("a"), validate: :off)
    |> Runic.Workflow.add(b_node, to: DagBuilder.node_atom("a__to__b__edge"), validate: :off)
  end

  describe "lifecycle event dispatch" do
    setup do
      test_pid = self()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        case event.request do
          {:broadcast, _topic, _message} -> :ok
          _ -> send(test_pid, {:dispatched, event})
        end

        event
      end)

      :ok
    end

    defp flush_dispatched do
      receive do
        {:dispatched, _} -> flush_dispatched()
      after
        0 -> :ok
      end
    end

    test "an unexpected raise on an edge finalizes the run 'failed', not 'incomplete'" do
      run = crashing_run()
      flush_dispatched()

      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "failed"
    end

    test "the edge's failed_steps entry is recorded on the run's log_summary" do
      run = crashing_run()

      {:ok, finished} = WorkflowRunAgent.execute(run)
      reloaded = Workflows.get_run!(finished.id)

      assert "a__to__b__edge" in reloaded.log_summary["failed_steps"]
    end

    test "the crashed edge has a 'failed' Step.Run row, not 'completed'" do
      run = crashing_run()

      {:ok, _finished} = WorkflowRunAgent.execute(run)

      step_runs = Workflows.list_step_runs(run.id)
      edge_run = Enum.find(step_runs, &(&1.step_name == "a__to__b__edge"))

      assert edge_run, "edge Step.Run row must exist"
      assert edge_run.status == "failed"
    end

    test "the pruned downstream node has no Step.Run row" do
      run = crashing_run()

      {:ok, _finished} = WorkflowRunAgent.execute(run)

      step_runs = Workflows.list_step_runs(run.id)
      names = Enum.map(step_runs, & &1.step_name)

      refute "b" in names
    end

    test "dispatches run.started then run.failed" do
      run = crashing_run()
      flush_dispatched()

      assert {:ok, _finished} = WorkflowRunAgent.execute(run)

      assert_received {:dispatched, started}
      assert started.request[:action] == "run.started"
      assert started.request[:run_id] == run.id

      assert_received {:dispatched, failed}
      assert failed.request[:action] == "run.failed"
      assert failed.request[:run_id] == run.id
    end
  end
end
