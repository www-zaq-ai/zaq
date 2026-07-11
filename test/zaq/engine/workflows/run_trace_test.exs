defmodule Zaq.Engine.Workflows.RunTraceTest do
  @moduledoc """
  Pins the per-run execution trace file contract (`Workflows.RunTrace`).

  When `config :zaq, :workflow_trace_dir` is set, a run must leave a single
  file at `<dir>/run_<run_id>.log` that tells the whole story on its own:
  input fact, every react cycle's new facts + next runnables (the Runic
  scheduler's view), every step/edge execution with I/O, the quiescent end
  state, and the finalize outcome. This is the diagnostic surface for
  "a node never ran and nothing says why" incidents — StepRun rows cannot
  show a node the scheduler never activated.

  When the config is unset (the default — it is only set when the app boots
  with `WORKFLOW_TRACE_ENABLED=true`, see `config/runtime.exs`), no file is
  written and the run is unaffected.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.RunTrace
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

    trace_dir =
      Path.join(System.tmp_dir!(), "zaq_run_trace_test_#{System.unique_integer([:positive])}")

    previous = Application.get_env(:zaq, :workflow_trace_dir)
    Application.put_env(:zaq, :workflow_trace_dir, trace_dir)

    on_exit(fn ->
      Application.put_env(:zaq, :workflow_trace_dir, previous)
      File.rm_rf(trace_dir)
    end)

    %{trace_dir: trace_dir}
  end

  # `a` (OkAction) emits %{value: "done"}; the edge condition compares against
  # `expected`, so the run either proceeds to leaf `b` or prunes it.
  defp run_with_edge_expecting(expected) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Trace Run #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{name: "a", type: "action", module: @ok_module, params: %{}, index: 0},
          %{name: "b", type: "action", module: @noop_module, params: %{}, index: 1}
        ],
        edges: [
          %{from: "a", to: "b", condition: %{field: "value", op: :eq, value: expected}}
        ]
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    run
  end

  describe "with :workflow_trace_dir set" do
    test "a completed run leaves a self-sufficient trace file" do
      run = run_with_edge_expecting("done")

      {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "completed"

      trace = File.read!(RunTrace.path(run.id))

      # Header carries the run identity and the initial input fact.
      assert trace =~ "run started"
      assert trace =~ run.id

      # The scheduler's view: at least one react cycle with the runnables Runic
      # scheduled next — the evidence StepRun rows structurally cannot provide.
      assert trace =~ "react cycle 1"
      assert trace =~ "next_runnables"
      assert trace =~ "new_facts"

      # Step-level I/O for both actions and the passing edge between them.
      assert trace =~ "step started — a"
      assert trace =~ "step completed — a"
      assert trace =~ "edge passed — a__to__b__edge"
      assert trace =~ "step completed — b"

      # End of run: quiescent scheduler state, then the finalize outcome.
      assert trace =~ "run quiescent"
      assert trace =~ "run finalized"
      assert trace =~ ~s(status: "completed")
    end

    test "a pruned branch records the failed edge condition with its actual value" do
      run = run_with_edge_expecting("never")

      {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "incomplete"

      trace = File.read!(RunTrace.path(run.id))

      assert trace =~ "edge condition not met — downstream pruned — a__to__b__edge"
      assert trace =~ ~s(actual: "done")
      assert trace =~ ~s(expected: "never")
      # The pruned leaf never appears as a started step.
      refute trace =~ "step started — b"
      assert trace =~ ~s(status: "incomplete")
    end
  end

  describe "with :workflow_trace_dir unset" do
    test "no trace file is written and the run is unaffected" do
      run = run_with_edge_expecting("done")
      Application.put_env(:zaq, :workflow_trace_dir, nil)

      refute RunTrace.enabled?()
      assert RunTrace.path(run.id) == nil

      {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "completed"
    end
  end
end
