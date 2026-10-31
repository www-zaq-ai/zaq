defmodule Zaq.Ingestion.JobLifecycle do
  @moduledoc false

  import Ecto.Query

  alias Zaq.Contracts.PreparationProgress
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Repo

  @pubsub Zaq.PubSub
  @topic "ingestion:jobs"

  @spec transition(IngestJob.t(), map()) :: {:ok, IngestJob.t()} | {:error, Ecto.Changeset.t()}
  def transition(%IngestJob{} = job, attrs) when is_map(attrs) do
    job
    |> IngestJob.changeset(attrs)
    |> clear_finished_preparation()
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_update(updated)
      _ -> :ok
    end)
  end

  @spec transition!(IngestJob.t(), map()) :: IngestJob.t()
  def transition!(%IngestJob{} = job, attrs) when is_map(attrs) do
    job
    |> IngestJob.changeset(attrs)
    |> clear_finished_preparation()
    |> Repo.update!()
    |> broadcast_update()
  end

  @spec mark_processing!(IngestJob.t()) :: IngestJob.t()
  def mark_processing!(%IngestJob{} = job) do
    transition!(job, %{
      status: "processing",
      started_at: DateTime.utc_now(),
      preparation_progress: nil
    })
  end

  @spec mark_completed!(IngestJob.t(), map()) :: IngestJob.t()
  def mark_completed!(%IngestJob{} = job, attrs) when is_map(attrs) do
    attrs = Map.merge(%{status: "completed", completed_at: DateTime.utc_now()}, attrs)
    transition!(job, attrs)
  end

  @spec mark_failed(IngestJob.t(), String.t(), keyword()) ::
          {:ok, IngestJob.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%IngestJob{} = job, error_message, opts \\ []) when is_binary(error_message) do
    attrs = %{status: "failed", error: error_message}

    attrs =
      if Keyword.get(opts, :completed, false) do
        Map.put(attrs, :completed_at, DateTime.utc_now())
      else
        attrs
      end

    transition(job, attrs)
  end

  @spec mark_failed!(IngestJob.t(), String.t(), keyword()) :: IngestJob.t()
  def mark_failed!(%IngestJob{} = job, error_message, opts \\ []) when is_binary(error_message) do
    attrs = %{status: "failed", error: error_message}

    attrs =
      if Keyword.get(opts, :completed, false) do
        Map.put(attrs, :completed_at, DateTime.utc_now())
      else
        attrs
      end

    transition!(job, attrs)
  end

  @spec mark_pending_retry!(IngestJob.t(), String.t()) :: IngestJob.t()
  def mark_pending_retry!(%IngestJob{} = job, error_message) when is_binary(error_message) do
    transition!(job, %{status: "pending", error: error_message})
  end

  @doc """
  Broadcasts a transient preparation-progress event for a job.

  Used for high-frequency, non-persisted progress (e.g. per-image image-to-text
  steps during PDF preparation). Rides the same PubSub topic as
  `{:job_updated, job}` so subscribed LiveViews receive it without extra wiring.
  Progress is deliberately not written to the database.
  """
  @spec broadcast_progress(Ecto.UUID.t(), map()) :: :ok
  def broadcast_progress(job_id, payload) when is_map(payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:job_progress, job_id, payload})
  end

  @doc """
  Saves valid preparation progress before broadcasting it to connected clients.

  Malformed supported fields return `{:error, :invalid_preparation_progress}`
  without changing the snapshot or broadcasting an event.
  """
  @spec report_preparation_progress(Ecto.UUID.t(), map()) ::
          :ok | {:error, :invalid_preparation_progress | Ecto.Changeset.t()}
  def report_preparation_progress(job_id, payload) when is_map(payload) do
    if PreparationProgress.valid?(payload) do
      save_preparation_progress(job_id, payload)
    else
      {:error, :invalid_preparation_progress}
    end
  end

  defp save_preparation_progress(job_id, payload) do
    result =
      Repo.transaction(fn ->
        job =
          Repo.one(
            from(j in IngestJob,
              where:
                j.id == ^job_id and j.status == "processing" and j.total_chunks == 0 and
                  is_nil(j.completed_at),
              lock: "FOR UPDATE"
            )
          )

        persist_preparation_progress(job, payload)
      end)

    case result do
      {:ok, :recorded} -> broadcast_progress(job_id, payload)
      {:ok, :ignored} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_preparation_progress(nil, _payload), do: :ignored

  defp persist_preparation_progress(job, payload) do
    snapshot = %{"payload" => payload, "reported_at" => DateTime.to_iso8601(DateTime.utc_now())}

    case job |> IngestJob.changeset(%{preparation_progress: snapshot}) |> Repo.update() do
      {:ok, _job} -> :recorded
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp clear_finished_preparation(changeset) do
    if Ecto.Changeset.get_field(changeset, :status) != "processing" or
         Ecto.Changeset.get_field(changeset, :total_chunks) > 0 or
         not is_nil(Ecto.Changeset.get_field(changeset, :completed_at)) do
      Ecto.Changeset.force_change(changeset, :preparation_progress, nil)
    else
      changeset
    end
  end

  defp broadcast_update(job) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:job_updated, job})
    job
  end

  @doc "Re-broadcasts a job after its document summary has been committed."
  def notify(%IngestJob{} = job), do: broadcast_update(job)
end
