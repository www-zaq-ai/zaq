defmodule Zaq.Engine.Connect.SecretReconciliationWorker do
  @moduledoc """
  Scheduled bounded orphan/attempt cleanup on its own consumed maintenance queue.
  DynamicCron's database leader schedules one unique run every five minutes. Each run
  processes one page and never recursively enqueues work; the next run starts from the
  earliest remaining eligible rows. Only counts/outcome/duration enter domain telemetry.
  """
  use Oban.Worker,
    queue: :connect_maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Zaq.Engine.Connect.{DeviceAttempts, PersonLifecycle}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started = System.monotonic_time()
    result = PersonLifecycle.reconcile()

    {outcome, counts} =
      case result do
        {:ok, result} -> device_cleanup(result)
        {:error, _} -> {:error, %{grants_deleted: 0, attempts_deleted: 0}}
      end

    :telemetry.execute(
      [:zaq, :connect, :secret_reconciliation],
      Map.put(counts, :duration, System.monotonic_time() - started),
      %{outcome: outcome}
    )

    if outcome == :ok, do: :ok, else: {:error, :reconciliation_failed}
  rescue
    _ -> {:error, :reconciliation_failed}
  end

  defp device_cleanup(result) do
    case DeviceAttempts.reconcile() do
      {:ok, count} ->
        {:ok,
         result
         |> Map.take([:grants_deleted, :attempts_deleted])
         |> Map.update!(:attempts_deleted, &(&1 + count))}

      _ ->
        {:error, Map.take(result, [:grants_deleted, :attempts_deleted])}
    end
  end
end
