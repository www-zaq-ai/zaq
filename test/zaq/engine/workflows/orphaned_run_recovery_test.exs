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
  alias Zaq.Engine.Workflows.Test.SignalListener
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  @sleep_module "Zaq.Agent.Tools.Workflow.Sleep"
  @ok_module "Zaq.Engine.Workflows.Test.OkAction"
  @run_registry Zaq.Engine.Workflows.RunRegistry

  # The screenshot's workflow in miniature: EmitItems → a `Batch` node ("process_rows")
  # whose `post_process` (`block_between`) signals the test and blocks, catching the run
  # mid-fan-out deterministically.
  defp batch_block_workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Batch DuplicateJoin #{System.unique_integer()}",
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
                  "name" => "block_between",
                  "type" => "action",
                  "module" => "Zaq.Engine.Workflows.Test.NotifyThenBlock",
                  "params" => %{}
                }
              ]
            },
            index: 1
          }
        ],
        edges: [%{from: "emit", to: "process_rows"}]
      })

    wf
  end

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
    assert recovered_step.errors["reason"] == "process_terminated"
    assert recovered_step.errors["message"] =~ "killed"
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
    assert recovered_step.errors["reason"] == "process_terminated"
    assert recovered_step.errors["message"] =~ "killed"
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

  # `:duplicate_join` is not a Runic/Jido bug: it exists only in Phoenix.Socket
  # (killing a channel on a duplicate join). ZAQ runs the DAG synchronously in ONE
  # process (`react/2` is serial, not `Task.async_stream`), so FanIn/FanOut spawn
  # nothing — the batch died only because it ran inside the LiveView channel. This
  # proves the single-process fact through the real Batch machinery (no kill, so it
  # stays reliable); the kill→interrupt reproduction lives in `run_watcher_test.exs`.
  describe "a real Batch/FanIn run executes in a single process (refutes the duplicate-process theory)" do
    setup do
      start_supervised!(SignalListener)
      SignalListener.listen(self())
      :ok
    end

    test "every fork of a real batch runs in the one driver process; Runic spawns none" do
      wf = batch_block_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      # `spawn_driver` runs the batch inline in `pid`, as the buggy sync path did in
      # the LiveView channel.
      pid = spawn_driver(run)
      ref = Process.monitor(pid)

      # The first post_process fork signals from inside the driver, then blocks.
      assert_receive {:fork_running, fork_pid}, 3_000

      # Single process: the fork runs in the same pid the run is registered under —
      # no second, library-spawned process for a stray exit to land on.
      assert fork_pid == pid
      assert [{^pid, _}] = Registry.lookup(@run_registry, run.id)

      # Release each fork (EmitItems yields 3 ⇒ forks 1 and 2 remain) to finish cleanly.
      send(pid, :release)

      Enum.each(1..2, fn _ ->
        assert_receive {:fork_running, ^pid}, 2_000
        send(pid, :release)
      end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      assert Workflows.get_run!(run.id).status == "completed"
    end
  end

  # `RunWatcher.handle_driver_down/2` already receives the driving process's
  # real `:DOWN` exit reason and logs it — but today it is thrown away before
  # `Workflows.interrupt_run/1` is called, which always writes the same fixed
  # `reason: "node_shutdown", message: "Server restarted during execution"`
  # regardless of what actually happened. That claim is false in every test in
  # this file: the node never restarts, RunWatcher recovers within the same
  # live node. These tests drive the driver process to death with distinct,
  # realistic exit reasons and assert the *real* reason is what gets stored.
  describe "the real termination reason is captured, not a fabricated node_shutdown label" do
    test "an uncaught exception on the driver surfaces its actual message" do
      wf = sleep_workflow(2_000)
      {:ok, run} = Workflows.create_run(wf, @source_event)

      pid = spawn_driver(run)
      ref = Process.monitor(pid)

      assert :ok = wait_until_running(run.id, "sleep_step", 1_000)

      # Shape produced when a process crashes via an uncaught `raise` — the
      # same `{exception, stacktrace}` DOWN reason OTP itself would deliver.
      crash_reason = {%RuntimeError{message: "disk full during batch write"}, []}
      Process.exit(pid, crash_reason)
      assert_receive {:DOWN, ^ref, :process, ^pid, ^crash_reason}, 1_000

      assert :ok = wait_until_not_running(run.id, "sleep_step", 1_000)

      recovered_step =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "sleep_step"))

      recovered_run = Workflows.get_run!(run.id)

      assert recovered_step.status == "failed"
      assert recovered_step.errors["reason"] == "process_terminated"
      assert recovered_step.errors["message"] =~ "disk full during batch write"
      refute recovered_step.errors["reason"] == "node_shutdown"
      refute recovered_step.errors["message"] =~ "Server restarted"

      assert recovered_run.status == "interrupted"
    end

    test "an arbitrary supervisor-style exit reason is captured verbatim, not hidden behind a generic label" do
      wf = sleep_workflow(2_000)
      {:ok, run} = Workflows.create_run(wf, @source_event)

      pid = spawn_driver(run)
      ref = Process.monitor(pid)

      assert :ok = wait_until_running(run.id, "sleep_step", 1_000)

      # No exception struct here — just an opaque supervisor/dependency exit
      # reason, the kind a real infra failure (e.g. a lost DB connection pool)
      # would produce. There is no known "reason code" for this: the fallback
      # must still surface it rather than collapsing to "node_shutdown".
      crash_reason = {:shutdown, :dependency_unavailable}
      Process.exit(pid, crash_reason)
      assert_receive {:DOWN, ^ref, :process, ^pid, ^crash_reason}, 1_000

      assert :ok = wait_until_not_running(run.id, "sleep_step", 1_000)

      recovered_step =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "sleep_step"))

      assert recovered_step.status == "failed"
      assert recovered_step.errors["reason"] == "process_terminated"
      assert recovered_step.errors["message"] =~ "dependency_unavailable"
      refute recovered_step.errors["reason"] == "node_shutdown"
    end

    test "control: a direct interrupt_run/1 call with no live exit signal (the boot-sweep path) keeps the honest node_shutdown label" do
      # This is what StartupRecovery/RunRecoveryWorker actually do at boot:
      # find a run stuck "running" with no driver process alive at all (the
      # node itself restarted) and call interrupt_run/1 with no opts. There is
      # genuinely no exit signal available in that scenario — "node_shutdown"
      # is the accurate label there. No driver/RunWatcher involved in this
      # test at all, so there's no race: this exercises the no-opts default
      # directly, proving RunWatcher's new live-signal path (tested above)
      # doesn't regress the boot-sweep path's own, separate call site.
      wf = sleep_workflow(2_000)
      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, _step_run} =
        Workflows.create_step_run(run, %{
          step_name: "sleep_step",
          step_index: 1,
          status: "running"
        })

      assert {:ok, interrupted} = Workflows.interrupt_run(run)
      assert interrupted.status == "interrupted"

      recovered_step =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "sleep_step"))

      assert recovered_step.status == "failed"
      assert recovered_step.errors["reason"] == "node_shutdown"
      assert recovered_step.errors["message"] == "Server restarted during execution"
    end
  end

  # Client report: a run's BO screen showed status "failed", yet one of its
  # steps was still shown as "running" — hanging forever. Traced to
  # `WorkflowRunAgent.finalize/2` (lib/zaq/engine/workflows/workflow_run_agent.ex:201-224),
  # whose own doc comment already called this out as the "crash cursor": a
  # `StepRun` row stuck at `"running"` is correctly treated as reason enough to
  # fail the *run*, but `finalize/2` only ever called `Workflows.update_run/2` —
  # it never reached back to resolve the stuck *step* itself. Fixed by
  # `Workflows.fail_orphaned_step_runs/2`, called from the same crash-cursor
  # branch right alongside the run update.
  #
  # This does not require killing any process (that path is RunWatcher's job,
  # tested above, and it already resolves the step correctly). It reproduces
  # with the driver very much alive: a `StepRun` left "running" by some earlier
  # partial attempt (e.g. a prior interrupted/crashed pass whose row a later
  # resume never revisits) simply sits in the table alongside a DAG that
  # otherwise runs to completion normally.
  describe "finalize/2's crash cursor fails the run AND resolves the stuck step (client-reported bug)" do
    test "a stray running StepRun fails the run and is itself resolved to failed" do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "Crash Cursor #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "fine", type: "action", module: @ok_module, params: %{}, index: 0}
          ],
          edges: []
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      # Simulates a step orphaned by an earlier, unrelated partial execution —
      # not one of this workflow's own nodes, so this run's DAG traversal never
      # visits or resolves it on its own.
      {:ok, _stray_step} =
        Workflows.create_step_run(run, %{
          step_name: "abandoned_step",
          step_index: 99,
          status: "running"
        })

      assert {:ok, finished_run} = WorkflowRunAgent.execute(run)

      # finalize/2 notices the stray "running" row and correctly fails the run
      # because of it ("crash cursor")...
      assert finished_run.status == "failed"

      reloaded_stray =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "abandoned_step"))

      fine_step =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "fine"))

      # ...the workflow's own step ran and completed normally, uninvolved in
      # the failure...
      assert fine_step.status == "completed"

      # ...and the fix: the very row that caused the run to fail is itself
      # resolved too — no more "run failed, step still running" inconsistency.
      assert reloaded_stray.status == "failed"
      assert reloaded_stray.errors["reason"] == "orphaned_step"
      refute is_nil(reloaded_stray.finished_at)
    end
  end
end
