defmodule Zaq.Engine.Workflows.RunWatcher do
  @moduledoc """
  Per-run orphan-crash detector for `WorkflowRunAgent.execute/2`.

  `execute/2` runs entirely inline, synchronously, in whatever process calls
  it — a throwaway task for a manual/triggered run, or (in tests, and any
  other direct caller) a long-lived process. If that process dies mid-run for
  any reason unrelated to the workflow itself (an unrelated supervisor
  restart, a code reload, an OOM kill), nothing previously noticed: the
  `WorkflowRun`/`StepRun` rows stayed at `"running"` forever, recoverable only
  by `Zaq.Engine.Workflows.StartupRecovery`, which fires exactly once, at BEAM
  boot.

  `watch/2` spawns one **disposable, per-run** sentinel (via
  `Zaq.TaskSupervisor` — not a shared/centralized process) that monitors the
  driving process. Deliberately not centralized: a slow recovery for one run
  must never delay another run's start or another run's recovery, and there is
  no shared mailbox for concurrent `watch/2` calls to queue behind.

  ## Lifecycle

  The sentinel's job ends the instant either:
  - `done/1` is called — the run's own `execute/2` call reached a normal,
    finalized outcome (completed, failed-via-`finalize/2`, waiting for
    approval, or paused). None of those are orphans; stop watching.
  - the driver dies unexpectedly (a `:DOWN` with any reason other than a
    `done/1` signal) — after a short grace window (to let a concurrent,
    *intentional* kill — `Workflows.cancel_run/1` / `pause_run/1` also
    hard-kill the driver, then immediately commit their own status update — win
    the race), it re-checks the run's live status and calls
    `Workflows.interrupt_run/1` only if the run is still non-terminal.

  Either way the sentinel terminates immediately after — it is scoped to *this
  invocation's* outcome, not to the calling process's entire remaining
  lifetime. A blanket `after`-based cleanup in the caller would be wrong here:
  `WorkflowRunAgent` deliberately lets an unexpected Runic-level crash
  propagate to its caller uncaught (see its moduledoc), and if `done/1` fired
  unconditionally on that unwind, orphan-recovery would be defeated for
  exactly the case it exists to catch. `done/1` is therefore only called from
  `WorkflowRunAgent`'s normal, non-raising return points.
  """

  require Logger

  alias Zaq.Engine.Workflows

  @grace_period_ms 200
  @watch_timeout_ms 1_000

  @doc """
  Starts watching `driver_pid` (default: the caller) on behalf of `run_id`.
  Blocks briefly until the sentinel confirms its monitor is live, so a driver
  that dies immediately after this call is never missed. Returns
  `{:ok, watcher_pid}` — pass it to `done/1` once the run's execution reaches a
  normal, finalized outcome.
  """
  @spec watch(String.t(), pid()) :: {:ok, pid()} | {:error, :watch_timeout}
  def watch(run_id, driver_pid \\ self()) when is_binary(run_id) and is_pid(driver_pid) do
    parent = self()
    ack = make_ref()

    {:ok, watcher_pid} =
      Task.Supervisor.start_child(Zaq.TaskSupervisor, fn ->
        mon_ref = Process.monitor(driver_pid)
        send(parent, {ack, :watching})
        await_outcome(run_id, mon_ref)
      end)

    receive do
      {^ack, :watching} -> {:ok, watcher_pid}
    after
      @watch_timeout_ms -> {:error, :watch_timeout}
    end
  end

  @doc """
  Signals that this run's `execute/2` call reached a normal, finalized
  outcome. The sentinel stops watching and terminates. Safe to call with `nil`
  (e.g. when `watch/2` itself failed to start a sentinel).
  """
  @spec done(pid() | nil) :: :ok
  def done(nil), do: :ok

  def done(watcher_pid) when is_pid(watcher_pid) do
    send(watcher_pid, :done)
    :ok
  end

  defp await_outcome(run_id, mon_ref) do
    receive do
      :done ->
        :ok

      {:DOWN, ^mon_ref, :process, _pid, reason} ->
        handle_driver_down(run_id, reason)
    end
  end

  defp handle_driver_down(run_id, reason) do
    # `cancel_run/1` and `pause_run/1` also hard-kill the driver, then commit
    # their own status update immediately after, synchronously. Give that
    # legitimate path a moment to land before treating this as an orphan.
    Process.sleep(@grace_period_ms)

    case Workflows.get_run(run_id) do
      %{status: status} = run when status in ["running", "pending"] ->
        Logger.warning(
          "[workflow] driving process died unexpectedly — recovering orphaned run " <>
            "run_id=#{run_id} exit_reason=#{inspect(reason)}"
        )

        Workflows.interrupt_run(run)
        :ok

      _ ->
        :ok
    end
  end
end
