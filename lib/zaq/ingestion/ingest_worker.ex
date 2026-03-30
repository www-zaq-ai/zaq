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
  alias Zaq.Ingestion.{FileExplorer, IngestJob, JobLifecycle}
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id} = args, attempt: attempt, max_attempts: max}) do
    role_id = Map.get(args, "role_id")
    shared_role_ids = Map.get(args, "shared_role_ids", [])
    job = Repo.get!(IngestJob, job_id)

    updated_job = JobLifecycle.mark_processing!(job)

    file_path = resolve_file_path(updated_job.file_path, updated_job.volume_name)
    telemetry_dimensions = %{mode: updated_job.mode, volume: updated_job.volume_name || "default"}

    case safe_process(file_path, role_id, shared_role_ids) do
      {:ok, document} ->
        chunks_count = count_chunks(document.id)

        Telemetry.record("ingestion.completed.count", 1, telemetry_dimensions)
        Telemetry.record("ingestion.chunks.created", chunks_count, telemetry_dimensions)

        JobLifecycle.mark_completed!(updated_job, %{
          chunks_count: chunks_count,
          document_id: document.id
        })

        :ok

      {:error, reason} ->
        Telemetry.record("ingestion.failed.count", 1, telemetry_dimensions)
        handle_error(updated_job, reason, attempt, max, telemetry_dimensions)
    end
  end

  defp handle_error(job, reason, attempt, max, telemetry_dimensions) do
    error_msg = format_error(reason)

    if attempt >= max or structural_error?(reason) do
      Telemetry.record("ingestion.document.failed.count", 1, telemetry_dimensions)

      label =
        if structural_error?(reason),
          do: "Structural error (not retriable): #{error_msg}",
          else: "Failed after #{max} attempts: #{error_msg}"

      JobLifecycle.mark_failed!(job, label, completed: true)

      {:cancel, reason}
    else
      JobLifecycle.mark_pending_retry!(job, "Attempt #{attempt} failed: #{error_msg}")

      {:error, reason}
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

  defp structural_error?(reason) when is_binary(reason) do
    String.contains?(reason, "Structural error")
  end

  defp structural_error?(:dimension_mismatch), do: true
  defp structural_error?(_), do: false

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{errors: _} = changeset), do: inspect(changeset.errors)
  defp format_error(reason), do: inspect(reason)

  defp processor do
    Application.get_env(:zaq, :document_processor, Zaq.Ingestion.DocumentProcessor)
  end
end
