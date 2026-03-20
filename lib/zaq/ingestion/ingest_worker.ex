defmodule Zaq.Ingestion.IngestWorker do
  @moduledoc """
  Oban worker for processing document ingestion jobs.
  Retries up to 3 times with 5s backoff, then marks the job as failed.
  """
  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    unique: [period: 120, fields: [:args]]

  import Ecto.Query
  require Logger

  alias Zaq.Engine.Telemetry
  alias Zaq.Ingestion.{FileExplorer, IngestJob}
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id} = args, attempt: attempt, max_attempts: max}) do
    role_id = Map.get(args, "role_id")
    shared_role_ids = Map.get(args, "shared_role_ids", [])
    job = Repo.get!(IngestJob, job_id)

    updated_job =
      job
      |> IngestJob.changeset(%{status: "processing", started_at: DateTime.utc_now()})
      |> Repo.update!()
      |> broadcast_update()

    file_path = resolve_file_path(updated_job.file_path, updated_job.volume_name)

    case safe_process(file_path, role_id, shared_role_ids) do
      {:ok, document} ->
        Telemetry.record("ingestion.completed.count", 1, %{
          mode: updated_job.mode,
          volume: updated_job.volume_name || "default"
        })

        updated_job
        |> IngestJob.changeset(%{
          status: "completed",
          completed_at: DateTime.utc_now(),
          chunks_count: count_chunks(document.id),
          document_id: document.id
        })
        |> Repo.update!()
        |> broadcast_update()

        :ok

      {:error, reason} ->
        error_msg = format_error(reason)

        Telemetry.record("ingestion.failed.count", 1, %{
          mode: updated_job.mode,
          volume: updated_job.volume_name || "default"
        })

        if attempt >= max do
          updated_job
          |> IngestJob.changeset(%{
            status: "failed",
            completed_at: DateTime.utc_now(),
            error: "Failed after #{max} attempts: #{error_msg}"
          })
          |> Repo.update!()
          |> broadcast_update()

          {:cancel, reason}
        else
          updated_job
          |> IngestJob.changeset(%{
            status: "pending",
            error: "Attempt #{attempt} failed: #{error_msg}"
          })
          |> Repo.update!()
          |> broadcast_update()

          {:error, reason}
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    attempt * 5
  end

  defp safe_process(file_path, role_id, shared_role_ids) do
    processor().process_single_file(file_path, role_id, shared_role_ids)
  rescue
    e ->
      Logger.error(
        "Ingestion crashed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, Exception.message(e)}
  catch
    kind, reason ->
      Logger.error("Ingestion caught #{kind}: #{inspect(reason)}")
      {:error, inspect(reason)}
  end

  defp resolve_file_path(path, nil) do
    case FileExplorer.resolve_path(path) do
      {:ok, full_path} -> full_path
      _ -> path
    end
  end

  defp resolve_file_path(path, volume_name) do
    case FileExplorer.resolve_path(volume_name, path) do
      {:ok, full_path} -> full_path
      _ -> path
    end
  end

  defp count_chunks(nil), do: 0

  defp count_chunks(document_id) do
    Repo.aggregate(
      from(c in Zaq.Ingestion.Chunk, where: c.document_id == ^document_id),
      :count
    )
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{errors: _} = changeset), do: inspect(changeset.errors)
  defp format_error(reason), do: inspect(reason)

  defp processor do
    Application.get_env(:zaq, :document_processor, Zaq.Ingestion.DocumentProcessor)
  end

  defp broadcast_update(job) do
    Phoenix.PubSub.broadcast(Zaq.PubSub, "ingestion:jobs", {:job_updated, job})
    job
  end
end
