defmodule Zaq.Engine.Workflows.RunIncompleteStatusTest do
  @moduledoc """
  RED test for Plan B — the "incomplete" run status.

  ## The bug this pins down

  When an edge condition evaluates false, `Steps.EdgeStep` raises `ConditionNotMet`
  and Runic prunes the downstream subgraph. The pruned action node's `StepRunner`
  never runs, so it writes **no** `Step.Run` row. `WorkflowRunAgent.finalize/2`
  today only inspects the rows that exist — it sees no `failed`/`running`/`waiting`
  rows and falls through to its `true ->` branch, marking the run `"completed"`.

  The result: a workflow whose *terminal* step was silently pruned reports success
  with no reason and no obvious log — exactly the client symptom that opened this
  investigation.

  ## The chosen contract (Option 3)

  A run that reaches quiescence **without a completed leaf node** must finalize as
  a new `"incomplete"` status — distinct from both `"completed"` and `"failed"` —
  so a silently-pruned terminal branch is visible instead of masquerading as
  success.

  ## Scenario

      a ──(condition: value == "never")──▶ b

  `a` (`OkAction`) emits `%{value: "done"}` and completes. The `a → b` edge
  condition (`value == "never"`) is therefore false, so `b` — the workflow's only
  leaf — is pruned and never writes a row. No leaf completed ⇒ the run must be
  `"incomplete"`.

  This test FAILS today (the run finalizes `"completed"`) and is expected to pass
  once `finalize/2` reconciles executed rows against the prepared DAG's leaf nodes.
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
