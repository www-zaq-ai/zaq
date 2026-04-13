defmodule Zaq.Ingestion.IngestWorker do
  @moduledoc """
  Oban worker — thin async entry point for the Jido ingestion pipeline.

  Delegates all orchestration to `Zaq.Ingestion.Agent.run/1`.

  Agent failures are treated as non-retryable: any `{:error, _}` result cancels the
  Oban job immediately (`{:cancel, :failed}`), leaving the IngestJob in `failed` status.
  This means the "failed" badge persists in the UI until the user manually retries.
  Infrastructure-level exceptions (e.g., DB connection failure) are not caught here —
  they surface as Oban exceptions and trigger the normal Oban retry/backoff cycle.
  """
  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    unique: [period: 120, fields: [:args]]

  alias Zaq.Ingestion.{Agent, IngestJob}
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id} = args}) do
    job = Repo.get!(IngestJob, job_id)
    upload_only = Map.get(args, "upload_only", false)

    case Agent.run(job, upload_only: upload_only) do
      {:ok, _updated_job} -> :ok
      {:error, _updated_job} -> {:cancel, :failed}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    attempt * 5
  end
end
