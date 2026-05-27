defmodule Zaq.Engine.Workflows.StartupRecovery do
  @moduledoc """
  One-shot task that runs when the engine node starts.

  Finds all `WorkflowRun` rows stuck in `"running"` or `"pending"` status —
  meaning the node was restarted while they were in flight — and marks each
  as `"interrupted"` via `Workflows.interrupt_run/1`.

  A failure to interrupt one run does not block the others.
  """

  use Task, restart: :transient

  require Logger

  alias Zaq.Engine.Workflows

  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  def run(_opts) do
    stale = workflows_mod().list_stale_runs()

    if stale == [] do
      Logger.info("[StartupRecovery] No stale workflow runs found")
    else
      results = Enum.map(stale, &interrupt_one/1)
      ok_count = Enum.count(results, &(&1 == :ok))
      err_count = Enum.count(results, &(&1 == :error))

      Logger.info(
        "[StartupRecovery] Interrupted #{ok_count} stale workflow run(s)" <>
          if(err_count > 0, do: ", #{err_count} failed", else: "")
      )
    end
  end

  defp interrupt_one(run) do
    case workflows_mod().interrupt_run(run) do
      {:ok, _} ->
        Logger.info("[StartupRecovery] Interrupted run #{run.id} (was #{run.status})")
        :ok

      {:error, reason} ->
        Logger.error("[StartupRecovery] Failed to interrupt run #{run.id}: #{inspect(reason)}")
        :error
    end
  end

  defp workflows_mod,
    do: Application.get_env(:zaq, :startup_recovery_workflows_mod, Workflows)
end
