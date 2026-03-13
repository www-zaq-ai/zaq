defmodule Zaq.Ingestion do
  @moduledoc """
  Public API for coordinating ingestion: trigger inline or async ingestion,
  query job statuses, retry and cancel jobs.
  """

  alias Zaq.Ingestion.{FileExplorer, IngestJob, IngestWorker}
  alias Zaq.Repo

  import Ecto.Query

  @pubsub Zaq.PubSub
  @topic "ingestion:jobs"

  # --- Ingestion triggers ---

  def ingest_file(path, mode \\ :async, volume_name \\ nil) do
    with {:ok, job} <- create_job(path, mode, volume_name) do
      case mode do
        :async ->
          %{"job_id" => job.id}
          |> IngestWorker.new()
          |> Oban.insert()

          {:ok, job}

        :inline ->
          IngestWorker.perform(%Oban.Job{args: %{"job_id" => job.id}})
          {:ok, Repo.get!(IngestJob, job.id)}
      end
    end
  end

  def ingest_folder(path, mode \\ :async, volume_name \\ nil) do
    with {:ok, entries} <- FileExplorer.list(path) do
      jobs =
        entries
        |> Enum.filter(&(&1.type == :file))
        |> Enum.map(fn entry ->
          file_path = Path.join(path, entry.name)
          {:ok, job} = ingest_file(file_path, mode, volume_name)
          job
        end)

      {:ok, jobs}
    end
  end

  # --- Job queries ---

  def list_jobs(opts \\ []) do
    status = Keyword.get(opts, :status)
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    IngestJob
    |> maybe_filter_status(status)
    |> order_by(desc: :inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  def get_job(id), do: Repo.get(IngestJob, id)

  # --- Job actions ---

  def retry_job(id) do
    with %IngestJob{status: "failed"} = job <- Repo.get(IngestJob, id),
         {:ok, job} <- update_job(job, %{status: "pending", error: nil, completed_at: nil}) do
      %{"job_id" => job.id}
      |> IngestWorker.new()
      |> Oban.insert()

      {:ok, job}
    else
      %IngestJob{} -> {:error, :not_failed}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def cancel_job(id) do
    with %IngestJob{status: "pending"} = job <- Repo.get(IngestJob, id),
         {:ok, job} <- update_job(job, %{status: "failed", error: "cancelled"}) do
      {:ok, job}
    else
      %IngestJob{} -> {:error, :not_pending}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # --- PubSub ---

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  # --- Private ---

  defp create_job(path, mode, volume_name) do
    attrs =
      %{file_path: path, status: "pending", mode: to_string(mode)}
      |> then(fn a -> if volume_name, do: Map.put(a, :volume_name, volume_name), else: a end)

    %IngestJob{}
    |> IngestJob.changeset(attrs)
    |> Repo.insert()
  end

  defp update_job(job, attrs) do
    job
    |> IngestJob.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_update(updated)
      _ -> :ok
    end)
  end

  defp broadcast_update(job) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:job_updated, job})
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [j], j.status == ^status)
end
