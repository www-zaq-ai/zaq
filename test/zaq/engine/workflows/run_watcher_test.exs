defmodule Zaq.Engine.Workflows.RunWatcherTest do
  @moduledoc """
  Unit-level tests for `Zaq.Engine.Workflows.RunWatcher` in isolation from
  `WorkflowRunAgent` — exercises `watch/2`/`done/1` directly against synthetic
  driver processes (not a real executing workflow), against the real
  `Workflows` context and DB (per this project's testing convention: cover
  risks through the real seam, don't stub the collaborator under test).

  `orphaned_run_recovery_test.exs` covers the same behavior end-to-end through
  a real `WorkflowRunAgent.execute/2` run; this file isolates `RunWatcher`'s
  own state machine so failures here point at `RunWatcher` specifically, not
  at the execution pipeline around it.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.RunWatcher

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp new_run(status \\ "running") do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "RunWatcher Unit #{System.unique_integer()}",
        status: "active",
        nodes: [%{name: "step", type: "action", module: @ok_module, params: %{}, index: 0}],
        edges: []
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    {:ok, run} = Workflows.update_run(run, %{status: status})
    run
  end

  # A synthetic "driver" — no real workflow execution, just a process that
  # RunWatcher can monitor and that the test controls directly.
  defp spawn_fake_driver do
    spawn(fn ->
      receive do
        :die_normally -> :ok
      end
    end)
  end

  defp wait_until(pred, deadline_ms) do
    t0 = System.monotonic_time(:millisecond)
    do_wait_until(pred, t0, deadline_ms)
  end

  defp do_wait_until(pred, t0, deadline_ms) do
    cond do
      pred.() ->
        :ok

      System.monotonic_time(:millisecond) - t0 > deadline_ms ->
        {:error, :timeout}

      true ->
        Process.sleep(10)
        do_wait_until(pred, t0, deadline_ms)
    end
  end

  test "watch/2 returns {:ok, pid} promptly, acked before returning" do
    run = new_run()
    driver = spawn_fake_driver()

    t0 = System.monotonic_time(:millisecond)
    assert {:ok, watcher_pid} = RunWatcher.watch(run.id, driver)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert is_pid(watcher_pid)
    assert Process.alive?(watcher_pid)
    assert elapsed < 500, "watch/2 took #{elapsed}ms — the handshake should be near-instant"

    send(driver, :die_normally)
  end

  test "done/1 signals the watcher to stop — a later driver death is not treated as an orphan" do
    run = new_run()
    driver = spawn_fake_driver()

    {:ok, watcher} = RunWatcher.watch(run.id, driver)
    ref = Process.monitor(watcher)

    :ok = RunWatcher.done(watcher)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 500

    # The driver dies *after* done/1 — the watcher is already gone and never
    # reacts, exactly as if the run had finished normally.
    send(driver, :die_normally)
    Process.sleep(100)

    untouched = Workflows.get_run!(run.id)
    assert untouched.status == "running"
  end

  test "done(nil) is a safe no-op" do
    assert :ok = RunWatcher.done(nil)
  end

  test "killing the driver before done/1 interrupts the run after the grace period" do
    run = new_run()
    driver = spawn_fake_driver()

    {:ok, _watcher} = RunWatcher.watch(run.id, driver)

    Process.exit(driver, :kill)

    # Immediately after the kill, still inside the grace window — not
    # interrupted yet.
    Process.sleep(50)
    assert Workflows.get_run!(run.id).status == "running"

    # Past the grace period, RunWatcher should have recovered it.
    assert :ok =
             wait_until(fn -> Workflows.get_run!(run.id).status != "running" end, 1_000)

    recovered = Workflows.get_run!(run.id)
    assert recovered.status == "interrupted"
    refute is_nil(recovered.finished_at)
  end

  test "a concurrent status change during the grace period wins — RunWatcher backs off" do
    run = new_run()
    driver = spawn_fake_driver()

    {:ok, _watcher} = RunWatcher.watch(run.id, driver)

    Process.exit(driver, :kill)

    # Simulate what cancel_run/1 or pause_run/1 do: commit a terminal status
    # of their own choosing while still inside RunWatcher's grace window.
    {:ok, _cancelled} = Workflows.update_run(run, %{status: "cancelled"})

    # Give RunWatcher's grace period + recheck plenty of time to run.
    Process.sleep(500)

    final = Workflows.get_run!(run.id)

    assert final.status == "cancelled",
           "expected the concurrent cancellation to win the race, " <>
             "got: #{inspect(final.status)} (RunWatcher should have backed off " <>
             "on seeing a non-running/pending status)"
  end

  test "multiple runs watched concurrently do not cross-contaminate" do
    run_a = new_run()
    run_b = new_run()
    driver_a = spawn_fake_driver()
    driver_b = spawn_fake_driver()

    {:ok, _} = RunWatcher.watch(run_a.id, driver_a)
    {:ok, _} = RunWatcher.watch(run_b.id, driver_b)

    # Only kill driver_a's process.
    Process.exit(driver_a, :kill)

    assert :ok =
             wait_until(fn -> Workflows.get_run!(run_a.id).status != "running" end, 1_000)

    assert Workflows.get_run!(run_a.id).status == "interrupted"

    # run_b's driver is still alive and was never touched — it must remain
    # untouched too.
    assert Process.alive?(driver_b)
    assert Workflows.get_run!(run_b.id).status == "running"

    send(driver_b, :die_normally)
  end

  # Reproduces the screenshot: the driver killed by Phoenix with
  # `{:shutdown, :duplicate_join}` → RunWatcher interrupts the run and fails the
  # in-flight step with the real reason in the banner message.
  test "driver killed with {:shutdown, :duplicate_join} interrupts the run and surfaces the reason" do
    run = new_run()
    driver = spawn_fake_driver()

    # An in-flight step — like the batch's `sleep_between[0]` in the screenshot.
    step_name = "process_rows/sleep_between[0]"

    {:ok, _in_flight} =
      Workflows.create_step_run(run, %{
        step_name: step_name,
        step_index: 0,
        status: "running"
      })

    {:ok, _watcher} = RunWatcher.watch(run.id, driver)

    Process.exit(driver, {:shutdown, :duplicate_join})

    assert :ok =
             wait_until(fn -> Workflows.get_run!(run.id).status != "running" end, 1_000)

    recovered = Workflows.get_run!(run.id)
    assert recovered.status == "interrupted"
    refute is_nil(recovered.finished_at)

    failed = Workflows.get_step_run_by_name(run.id, step_name)
    assert failed.status == "failed"
    assert failed.errors["reason"] == "process_terminated"
    # The banner shows the real exit reason verbatim, not a generic sentence.
    assert failed.errors["message"] =~ "{:shutdown, :duplicate_join}"
  end

  test "a run that is already terminal when the driver dies is left alone" do
    run = new_run("completed")
    driver = spawn_fake_driver()

    {:ok, _watcher} = RunWatcher.watch(run.id, driver)
    Process.exit(driver, :kill)

    Process.sleep(400)

    untouched = Workflows.get_run!(run.id)
    assert untouched.status == "completed"
  end
end
