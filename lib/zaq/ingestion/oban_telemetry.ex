defmodule Zaq.Ingestion.ObanTelemetry do
  @moduledoc """
  Telemetry handler for Oban ingestion job events.
  Marks IngestJob as failed when Oban discards the job after max retries.
  """

  alias Zaq.Engine.Telemetry
  alias Zaq.Ingestion.{IngestJob, JobLifecycle}
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
         {:ok, _updated} <-
           JobLifecycle.mark_failed(job, "Max retries exhausted", completed: true) do
      Telemetry.record("ingestion.discarded.count", 1, %{worker: meta.job.worker})
    else
      _ -> :ok
    end
  end
end
