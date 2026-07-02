defmodule Zaq.Engine.Workflows.OrphanedRunRecoveryTest do
  @moduledoc """
  Validates (empirically, not just by reading the code) the fix for a client
  report: a workflow run's BO screen showed a `post_process` `sleep_between`
  step "running" for 2m9s against a configured 10s `duration_ms` — with zero
  log output.

  `Process.sleep/1` cannot itself run longer than requested (BEAM guarantee),
  so a single call blocking past its duration was ruled out. The actual cause:
  the process driving `WorkflowRunAgent.execute/2` died mid-step (crash, kill,
  node issue) while `Process.sleep` was in flight, and nothing recovered the
  orphaned `WorkflowRun`/`StepRun` rows except
  `Zaq.Engine.Workflows.StartupRecovery` — a **one-shot task that only runs
  when the engine node boots** (`lib/zaq/engine/supervisor.ex`). If the
  driving process died without a full node restart, the rows were stuck at
  `"running"` forever, and the BO UI's timer (`format_live_duration/3` in
  `workflow_components.ex`) — just `DateTime.diff(now, started_at)` — showed an
  ever-growing duration with no way to know the process was gone.

  Fix: `Zaq.Engine.Workflows.RunWatcher` spawns a disposable, per-run sentinel
  (via `Zaq.TaskSupervisor`) alongside every `WorkflowRunAgent.execute/2` call,
  monitoring the driving process. If it dies unexpectedly, the sentinel
  recovers the run itself — immediately, not at next boot — via the same
  `Workflows.interrupt_run/1` that `StartupRecovery` already used. The
  boot-time sweep remains in place as a fallback for the case per-process
  monitoring cannot cover: the *entire node* going down (nothing survives that
  to react).

  These tests kill the driving process mid-`Process.sleep` (simulating a
  crash) and confirm the run is auto-recovered within milliseconds — not stuck
  forever, and not dependent on a node restart.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  @sleep_module "Zaq.Agent.Tools.Workflow.Sleep"
  @ok_module "Zaq.Engine.Workflows.Test.OkAction"

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp sleep_workflow(duration_ms) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Orphan Recovery #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{name: "fast", type: "action", module: @ok_module, params: %{}, index: 0},
          %{
            name: "sleep_step",
            type: "action",
            module: @sleep_module,
            params: %{"duration_ms" => duration_ms},
            index: 1
          }
        ],
        edges: [%{from: "fast", to: "sleep_step"}]
      })

    wf
  end

  # Waits (polling, bounded) for a StepRun with the given name to reach
  # `status: "running"` — i.e. the driving process is now blocked inside
  # `Process.sleep/1` for that step.
  defp wait_until_running(run_id, step_name, deadline_ms) do
    t0 = System.monotonic_time(:millisecond)
    do_wait_until(run_id, step_name, &(&1 == "running"), t0, deadline_ms)
  end

  # Waits for a StepRun to leave "running" (i.e. RunWatcher's recovery landed).
  defp wait_until_not_running(run_id, step_name, deadline_ms) do
    t0 = System.monotonic_time(:millisecond)
    do_wait_until(run_id, step_name, &(&1 != "running"), t0, deadline_ms)
  end

  defp do_wait_until(run_id, step_name, pred, t0, deadline_ms) do
    row = run_id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == step_name))

    cond do
      row && pred.(row.status) ->
        :ok

      System.monotonic_time(:millisecond) - t0 > deadline_ms ->
        {:error, :timeout, row}

      true ->
        Process.sleep(10)
        do_wait_until(run_id, step_name, pred, t0, deadline_ms)
    end
  end

  # Spawn un-linked (not Task.async, which links) so killing it doesn't crash
  # the test process — this mirrors an independent process (LiveView handler,
  # Oban job, etc.) driving the run in production. Mox/Sandbox ownership
  # resolution walks `$callers` (the same mechanism `Task.start/1` sets up), so
  # we propagate it by hand instead of an explicit `Sandbox.allow` — killing an
  # explicitly-allowed process tears down the shared connection along with it.
  defp spawn_driver(run) do
    callers = [self() | Process.get(:"$callers", [])]

    spawn(fn ->
      Process.put(:"$callers", callers)
      WorkflowRunAgent.execute(run)
    end)
  end

  test "killing the driving process mid-sleep auto-recovers the run within milliseconds" do
    wf = sleep_workflow(2_000)
    {:ok, run} = Workflows.create_run(wf, @source_event)

    pid = spawn_driver(run)
    ref = Process.monitor(pid)

    assert :ok = wait_until_running(run.id, "sleep_step", 1_000)

    # Simulate the driving process dying mid-step (crash / OOM kill / etc.) —
    # NOT a graceful pause, NOT the node restarting.
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    # sleep_step was configured for 2s — recovery should land well within
    # that, proving it's RunWatcher reacting to the death, not some other
    # process eventually timing out on its own.
    assert :ok = wait_until_not_running(run.id, "sleep_step", 1_000)

    recovered_step =
      run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "sleep_step"))

    recovered_run = Workflows.get_run!(run.id)

    assert recovered_step.status == "failed"
    assert recovered_step.errors["reason"] == "node_shutdown"
    refute is_nil(recovered_step.finished_at)

    assert recovered_run.status == "interrupted"
    refute is_nil(recovered_run.finished_at)
  end

  test "control: a normally-completing run is never touched by RunWatcher" do
    wf = sleep_workflow(50)
    {:ok, run} = Workflows.create_run(wf, @source_event)

    pid = spawn_driver(run)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    finished = Workflows.get_run!(run.id)
    assert finished.status == "completed"
  end

  # cancel_run/1 and pause_run/1 both hard-kill the driver (via
  # `Registry.lookup(RunRegistry, run.id)` + `Process.exit(pid, :kill)`) and
  # then commit their own status update — the exact race RunWatcher's grace
  # period exists to lose gracefully. These prove it with a *real* driver
  # process (registered via the real `Registry.register/3` call inside
  # `WorkflowRunAgent.execute/2`), not the synthetic one in
  # `run_watcher_test.exs`.
  describe "cancel_run/1 and pause_run/1 race RunWatcher — the intentional kill must win" do
    test "cancel_run/1 during a live step ends the run cancelled, not interrupted" do
      wf = sleep_workflow(2_000)
      {:ok, run} = Workflows.create_run(wf, @source_event)

      pid = spawn_driver(run)
      ref = Process.monitor(pid)

      assert :ok = wait_until_running(run.id, "sleep_step", 1_000)

      assert {:ok, cancelled} = Workflows.cancel_run(Workflows.get_run!(run.id))
      assert cancelled.status == "cancelled"

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      # Give RunWatcher's grace period + recheck plenty of time to run and
      # (incorrectly, if there's a regression) overwrite the status.
      Process.sleep(500)

      final = Workflows.get_run!(run.id)

      assert final.status == "cancelled",
             "expected cancel_run/1's own status to win the race with RunWatcher, " <>
               "got: #{inspect(final.status)}"
    end

    test "pause_run/1 during a live step ends the run paused, not interrupted" do
      wf = sleep_workflow(2_000)
      {:ok, run} = Workflows.create_run(wf, @source_event)

      pid = spawn_driver(run)
      ref = Process.monitor(pid)

      assert :ok = wait_until_running(run.id, "sleep_step", 1_000)

      assert {:ok, paused} = Workflows.pause_run(Workflows.get_run!(run.id))
      assert paused.status == "paused"

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      Process.sleep(500)

      final = Workflows.get_run!(run.id)

      assert final.status == "paused",
             "expected pause_run/1's own status to win the race with RunWatcher, " <>
               "got: #{inspect(final.status)}"
    end
  end

  test "a hard self-kill mid-step (not a graceful failure) is still recovered by RunWatcher" do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Self Destruct #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "boom",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.SelfDestruct",
            params: %{},
            index: 0
          }
        ],
        edges: []
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)

    pid = spawn_driver(run)
    ref = Process.monitor(pid)

    # `Process.exit(self(), :kill)` is untrappable — it bypasses
    # `StepRunner`'s own `rescue` entirely and kills the driver outright, the
    # same as an external OOM kill. Nothing in the call stack ever gets a
    # chance to call `RunWatcher.done/1`.
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert :ok = wait_until_not_running(run.id, "boom", 1_000)

    recovered_step = run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "boom"))
    recovered_run = Workflows.get_run!(run.id)

    assert recovered_step.status == "failed"
    assert recovered_step.errors["reason"] == "node_shutdown"
    assert recovered_run.status == "interrupted"
  end

  test "a realistic multi-fork batch run completes normally — RunWatcher never fires" do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Batch Reassurance #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitItems",
            params: %{},
            index: 0
          },
          %{
            name: "process_rows",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.Batch",
            params: %{
              "delivery" => "list",
              "strategy" => "skip_and_continue",
              "process" => [
                %{
                  "name" => "categorize",
                  "type" => "action",
                  "module" => "Zaq.Engine.Workflows.Test.CategorizeBySize",
                  "params" => %{}
                }
              ],
              "post_process" => [
                %{
                  "name" => "sleep_between",
                  "type" => "action",
                  "module" => @sleep_module,
                  "params" => %{"duration_ms" => 100}
                }
              ]
            },
            index: 1
          }
        ],
        edges: [%{from: "emit", to: "process_rows"}]
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)

    pid = spawn_driver(run)
    ref = Process.monitor(pid)

    # EmitItems produces 3 items; each fork body is fast but post_process
    # sleeps 100ms and forks run sequentially, so this genuinely spans several
    # hundred ms of real execution — long enough for a spurious RunWatcher
    # false-positive to have a window to occur, if there were one.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000

    finished = Workflows.get_run!(run.id)
    assert finished.status == "completed"
    refute finished.status == "interrupted"
  end
end
