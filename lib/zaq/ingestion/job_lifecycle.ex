defmodule Zaq.Ingestion.JobLifecycle do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Zaq.Ingestion.IngestJob
  alias Zaq.Repo

  @pubsub Zaq.PubSub
  @topic "ingestion:jobs"

  @spec transition(IngestJob.t(), map()) :: {:ok, IngestJob.t()} | {:error, Ecto.Changeset.t()}
  def transition(%IngestJob{} = job, attrs) when is_map(attrs) do
    job
    |> IngestJob.changeset(attrs)
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
    |> Repo.update!()
    |> broadcast_update()
  end

  @spec mark_processing!(IngestJob.t()) :: IngestJob.t()
  def mark_processing!(%IngestJob{} = job) do
    transition!(job, %{status: "processing", started_at: DateTime.utc_now()})
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

  @spec mark_converted!(IngestJob.t(), map()) :: IngestJob.t()
  def mark_converted!(%IngestJob{} = job, attrs \\ %{}) do
    transition!(job, Map.merge(%{status: "converted"}, attrs))
  end

  @spec mark_pending_retry!(IngestJob.t(), String.t()) :: IngestJob.t()
  def mark_pending_retry!(%IngestJob{} = job, error_message) when is_binary(error_message) do
    transition!(job, %{status: "pending", error: error_message})
  end

  @doc """
  Sets `total_chunks` and resets progress counters to zero at the start of embedding.
  Broadcasts so the LiveView can show the denominator immediately (e.g. "0 / 14").
  """
  @spec set_total_chunks!(any(), non_neg_integer()) :: :ok
  def set_total_chunks!(job_id, total) when is_integer(total) and total >= 0 do
    {1, [job]} =
      Repo.update_all(
        from(j in IngestJob, where: j.id == ^job_id, select: j),
        set: [total_chunks: total, chunks_count: total, ingested_chunks: 0, failed_chunks: 0]
      )

    broadcast_update(job)
    :ok
  end

  @doc """
  Atomically increments either `ingested_chunks` or `failed_chunks` after each
  chunk is embedded. Broadcasts so the LiveView updates in real time (e.g. "3 / 14").
  """
  @spec increment_chunk_progress!(any(), :ingested | :failed) :: :ok
  def increment_chunk_progress!(job_id, :ingested), do: do_increment(job_id, :ingested_chunks)
  def increment_chunk_progress!(job_id, :failed), do: do_increment(job_id, :failed_chunks)

  defp do_increment(job_id, field) when field in [:ingested_chunks, :failed_chunks] do
    {1, [job]} =
      Repo.update_all(
        from(j in IngestJob, where: j.id == ^job_id, select: j),
        inc: [{field, 1}]
      )

    broadcast_update(job)
    :ok
  end

  defp broadcast_update(job) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:job_updated, job})
    job
  end
end
