defmodule Zaq.Engine.Workflows.RunRecoveryWorker do
  @moduledoc """
  Oban worker that recovers a single workflow run orphaned by a node restart.

  On engine boot, `Zaq.Engine.Workflows.StartupRecovery` enqueues one job per
  stale run (via `enqueue_all/1`). Each job marks its run as `"interrupted"`
  through `Workflows.interrupt_run/1`. Splitting recovery into per-run Oban jobs
  makes the work tracked and retryable — a failure to recover one run no longer
  silently swallows the error or blocks the others.

  Jobs are unique on `run_id` so a duplicate enqueue (e.g. overlapping boots) is
  a no-op while a recovery is still pending or executing.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [keys: [:run_id], period: :infinity]

  require Logger

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRun
  alias Zaq.Repo

  @doc """
  Enqueues one unique recovery job per stale run. Returns the number of jobs
  actually inserted (duplicates deduped by the unique constraint are not
  counted).
  """
  @spec enqueue_all(keyword()) :: non_neg_integer()
  def enqueue_all(_opts \\ []) do
    workflows_mod().list_stale_runs()
    |> Enum.reduce(0, fn run, acc ->
      case %{run_id: run.id} |> new() |> Oban.insert() do
        {:ok, %Oban.Job{conflict?: true}} -> acc
        {:ok, %Oban.Job{}} -> acc + 1
        {:error, _} -> acc
      end
    end)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Repo.get(WorkflowRun, run_id) do
      nil ->
        Logger.info("[RunRecovery] run #{run_id} no longer exists — nothing to recover")
        :ok

      %WorkflowRun{} = run ->
        case workflows_mod().interrupt_run(run) do
          {:ok, _interrupted} ->
            Logger.info("[RunRecovery] interrupted run #{run_id} (was #{run.status})")
            :ok

          {:error, reason} = error ->
            Logger.error("[RunRecovery] failed to interrupt run #{run_id}: #{inspect(reason)}")
            error
        end
    end
  end

  defp workflows_mod,
    do: Application.get_env(:zaq, :startup_recovery_workflows_mod, Workflows)
end
