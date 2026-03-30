defmodule Zaq.Ingestion.JobLifecycle do
  @moduledoc false

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

  @spec mark_pending_retry!(IngestJob.t(), String.t()) :: IngestJob.t()
  def mark_pending_retry!(%IngestJob{} = job, error_message) when is_binary(error_message) do
    transition!(job, %{status: "pending", error: error_message})
  end

  defp broadcast_update(job) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:job_updated, job})
    job
  end
end
