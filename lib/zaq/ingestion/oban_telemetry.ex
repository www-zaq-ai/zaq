defmodule Zaq.Ingestion.ObanTelemetry do
  @moduledoc """
  Telemetry handler for Oban ingestion job events.
  Marks IngestJob as failed when Oban discards the job after max retries.
  """

  alias Zaq.Engine.Telemetry
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Repo

  def attach do
    :telemetry.attach(
      "oban-ingestion-discarded",
      [:oban, :job, :exception],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(_event, _measure, meta, _config) do
    with true <- meta.job.worker == "Zaq.Ingestion.IngestWorker",
         true <- meta.state == :discard,
         job_id when not is_nil(job_id) <- meta.job.args["job_id"],
         %IngestJob{status: status} = job when status != "failed" <- Repo.get(IngestJob, job_id),
         {:ok, updated} <- mark_failed(job) do
      Telemetry.record("ingestion.discarded.count", 1, %{worker: meta.job.worker})
      Phoenix.PubSub.broadcast(Zaq.PubSub, "ingestion:jobs", {:job_updated, updated})
    else
      _ -> :ok
    end
  end

  defp mark_failed(job) do
    job
    |> IngestJob.changeset(%{
      status: "failed",
      error: "Max retries exhausted",
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end
end
