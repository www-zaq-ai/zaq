defmodule Zaq.Engine.Workflows.RunIncompleteStatusTest do
  @moduledoc """
  Verifies the "incomplete" run status contract (Plan B).

  ## The behavior this pins down

  When an edge condition evaluates false, `Steps.EdgeStep` raises `ConditionNotMet`
  and Runic prunes the downstream subgraph. The pruned action node's `StepRunner`
  never runs, so it writes **no** `Step.Run` row. If `WorkflowRunAgent.finalize/2`
  only inspected the rows that exist, it would see no `failed`/`running`/`waiting`
  rows and fall through to its `true ->` branch, wrongly marking the run
  `"completed"` — a workflow whose *terminal* step was silently pruned would
  report success with no reason and no obvious log.

  ## The contract (Option 3)

  A run that reaches quiescence **without a completed leaf node** finalizes as a
  distinct `"incomplete"` status — separate from both `"completed"` and
  `"failed"` — so a silently-pruned terminal branch is visible instead of
  masquerading as success. `finalize/2` reconciles the executed rows against the
  prepared DAG's leaf nodes to detect this.

  ## Scenario

      a ──(condition: value == "never")──▶ b

  `a` (`OkAction`) emits `%{value: "done"}` and completes. The `a → b` edge
  condition (`value == "never"`) is therefore false, so `b` — the workflow's only
  leaf — is pruned and never writes a row. No leaf completed ⇒ the run finalizes
  `"incomplete"`.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"
  @noop_module "Zaq.Engine.Workflows.Test.Noop"

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp linear_pruned_run do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Incomplete Run #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{name: "a", type: "action", module: @ok_module, params: %{}, index: 0},
          %{name: "b", type: "action", module: @noop_module, params: %{}, index: 1}
        ],
        edges: [
          # `a` emits %{value: "done"}, so this condition is always false → `b` pruned.
          %{from: "a", to: "b", condition: %{field: "value", op: :eq, value: "never"}}
        ]
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    run
  end

  describe "finalize/2 — a run whose terminal branch is silently pruned" do
    test "finalizes as incomplete, not completed" do
      run = linear_pruned_run()

      {:ok, finished} = WorkflowRunAgent.execute(run)

      # Sanity: this is the silent-prune shape — `a` ran, the terminal leaf `b`
      # never wrote a row. If either of these is false the scenario is wrong and
      # the status assertion below would pass/fail for the wrong reason.
      by_name = Map.new(Workflows.list_step_runs(finished.id), &{&1.step_name, &1.status})
      assert by_name["a"] == "completed"
      refute Map.has_key?(by_name, "b")

      # The actual contract under test.
      assert finished.status == "incomplete",
             ~s(expected a run with a pruned terminal leaf to finalize as "incomplete", ) <>
               ~s(got #{inspect(finished.status)} — silent false-success)
    end
  end
end
