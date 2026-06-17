defmodule Zaq.Engine.Workflows.StartupRecovery do
  @moduledoc """
  One-shot task that runs when the engine node starts.

  Finds all `WorkflowRun` rows stuck in `"running"` or `"pending"` status —
  meaning the node was restarted while they were in flight — and enqueues one
  `Zaq.Engine.Workflows.RunRecoveryWorker` job per run. The actual recovery
  (marking each run `"interrupted"`) happens in the worker, so the work is
  tracked and retryable rather than swept inline.
  """

  use Task, restart: :transient

  require Logger

  alias Zaq.Engine.Workflows.RunRecoveryWorker

  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  def run(_opts) do
    case RunRecoveryWorker.enqueue_all() do
      0 ->
        Logger.info("[StartupRecovery] No stale workflow runs found")

      count ->
        Logger.info("[StartupRecovery] Enqueued recovery for #{count} stale workflow run(s)")
    end

    :ok
  end
end
