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

  alias Zaq.Ingestion.{
    Chunk,
    ExternalPermissions,
    FileExplorer,
    IngestChunkJob,
    IngestChunkWorker,
    IngestJob,
    JobLifecycle,
    RecordSource
  }

  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id} = args, attempt: attempt, max_attempts: max}) do
    job = Repo.get!(IngestJob, job_id)

    updated_job = JobLifecycle.mark_processing!(job)

    materialized = materialize_job(updated_job)
    telemetry_dimensions = %{mode: updated_job.mode, volume: updated_job.volume_name || "default"}

    if Map.get(args, "retry_failed_chunks", false) do
      requeue_failed_chunk_jobs(updated_job, telemetry_dimensions)
    else
      try do
        case materialized do
          {:ok, input} ->
            process_materialized_input(input, updated_job, telemetry_dimensions, attempt, max)

          {:error, reason} ->
            handle_error(updated_job, reason, attempt, max, telemetry_dimensions)
        end
      after
        cleanup_materialized(materialized)
      end
    end
  end

  defp process_materialized_input(input, job, telemetry_dimensions, attempt, max) do
    case prepare_chunks(input.path, job, input.processor_opts || []) do
      {:ok, document, :legacy_completed} ->
        import_external_permissions(input, document)
        finalize_legacy_job(job, document, telemetry_dimensions)

      {:ok, document, indexed_payloads} ->
        import_external_permissions(input, document)
        schedule_chunk_jobs(job, document, indexed_payloads, telemetry_dimensions)

      {:error, reason} ->
        handle_error(job, reason, attempt, max, telemetry_dimensions)
    end
  end

  defp handle_error(job, reason, attempt, max, telemetry_dimensions) do
    error_msg = format_error(reason)

    if attempt >= max or structural_error?(reason) do
      label =
        if structural_error?(reason),
          do: "Structural error (not retriable): #{error_msg}",
          else: "Failed after #{max} attempts: #{error_msg}"

      Telemetry.record("ingestion.document.failed.final.count", 1, telemetry_dimensions)

      JobLifecycle.mark_failed!(job, label, completed: true)

      {:cancel, reason}
    else
      JobLifecycle.mark_pending_retry!(job, "Attempt #{attempt} failed: #{error_msg}")
      Telemetry.record("ingestion.retry.count", 1, telemetry_dimensions)

      {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    attempt * 5
  end

  # Builds the callback handed to the Python runner. Each decoded progress
  # payload is fanned out over PubSub so subscribed BO LiveViews can show
  # preparation progress. Failures here must never break ingestion.
  defp progress_reporter(job) do
    fn payload ->
      _ = JobLifecycle.broadcast_progress(job.id, payload)
      :ok
    end
  end

  defp prepare_chunks(file_path, job, opts) do
    proc = processor()
    opts = Keyword.merge(opts, on_progress: progress_reporter(job))

    if function_exported?(proc, :prepare_file_chunks, 2) do
      proc.prepare_file_chunks(file_path, opts)
    else
      case proc.process_single_file(file_path) do
        {:ok, document} ->
          {:ok, document, :legacy_completed}

        {:error, reason} ->
          {:error, reason}
      end
    end
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

  defp materialize_job(%IngestJob{source_record: source_record}) when is_map(source_record) do
    with {:ok, record} <- RecordSource.from_storage_map(source_record) do
      RecordSource.materialize(record)
    end
  end

  defp materialize_job(%IngestJob{} = job) do
    path = resolve_file_path(job)

    if external_sidecar_path?(path) do
      {:error, :external_sidecar_requires_source_record}
    else
      {:ok, %{path: path, processor_opts: [], cleanup_paths: []}}
    end
  end

  defp external_sidecar_path?(path) when is_binary(path),
    do: path |> Path.split() |> Enum.member?(".external-sidecars")

  defp external_sidecar_path?(_path), do: false

  defp cleanup_materialized({:ok, %{cleanup_paths: paths}}) when is_list(paths) do
    Enum.each(paths, &cleanup_materialized_path/1)
  end

  defp cleanup_materialized(_), do: :ok

  defp cleanup_materialized_path(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        # Cleanup is best-effort; another process may have already removed it.
        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove materialized ingestion file #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp import_external_permissions(%{record: record, processor_opts: opts}, document) do
    sidecar_source = Keyword.get(opts, :sidecar_source_override)

    docs =
      [document, sidecar_source && Repo.get_by(Zaq.Ingestion.Document, source: sidecar_source)]
      |> Enum.reject(&is_nil/1)

    if docs != [] and record do
      ExternalPermissions.apply(record, docs)
    end
  end

  defp import_external_permissions(_input, _document), do: :ok

  defp schedule_chunk_jobs(job, document, indexed_payloads, telemetry_dimensions) do
    Chunk.delete_by_document(document.id)
    IngestChunkJob.upsert_many(job.id, document.id, indexed_payloads)

    attrs = %{
      document_id: document.id,
      total_chunks: length(indexed_payloads),
      ingested_chunks: 0,
      failed_chunks: 0,
      failed_chunk_indices: [],
      chunks_count: 0,
      error: nil
    }

    JobLifecycle.transition!(job, attrs)

    Enum.each(indexed_payloads, fn {_payload, index} ->
      %{"job_id" => job.id, "chunk_index" => index}
      |> chunk_job_args(job.id)
      |> IngestChunkWorker.new()
      |> Oban.insert()
    end)

    Telemetry.record(
      "ingestion.chunk.scheduled.count",
      length(indexed_payloads),
      telemetry_dimensions
    )

    :ok
  end

  defp finalize_legacy_job(job, document, telemetry_dimensions) do
    chunks_count = if is_nil(document.id), do: 0, else: Chunk.count_by_document(document.id)

    JobLifecycle.mark_completed!(job, %{
      document_id: document.id,
      chunks_count: chunks_count,
      total_chunks: chunks_count,
      ingested_chunks: chunks_count,
      failed_chunks: 0,
      failed_chunk_indices: []
    })

    Telemetry.record("ingestion.completed.count", 1, telemetry_dimensions)
    Telemetry.record("ingestion.chunks.created", chunks_count, telemetry_dimensions)
    :ok
  end

  defp requeue_failed_chunk_jobs(job, telemetry_dimensions) do
    failed_chunks = IngestChunkJob.list_failed_final(job.id)

    if failed_chunks == [] do
      JobLifecycle.transition!(job, %{
        status: "completed_with_errors",
        completed_at: DateTime.utc_now()
      })

      :ok
    else
      {_count, _} = IngestChunkJob.requeue_failed_final(job.id)

      JobLifecycle.transition!(job, %{
        status: "processing",
        completed_at: nil,
        error: nil
      })

      Enum.each(failed_chunks, fn chunk_job ->
        %{"job_id" => job.id, "chunk_job_id" => chunk_job.id}
        |> IngestChunkWorker.new()
        |> Oban.insert()
      end)

      Telemetry.record(
        "ingestion.chunk.requeued.count",
        length(failed_chunks),
        telemetry_dimensions
      )

      :ok
    end
  end

  defp chunk_job_args(%{"job_id" => job_id, "chunk_index" => chunk_index}, ingest_job_id) do
    chunk_job =
      IngestChunkJob
      |> where([c], c.ingest_job_id == ^ingest_job_id and c.chunk_index == ^chunk_index)
      |> Repo.one!()

    %{"job_id" => job_id, "chunk_job_id" => chunk_job.id}
  end

  defp resolve_file_path(%IngestJob{source_record: source_record}) when is_map(source_record) do
    # DB persistence stores source records as maps; runtime source resolution
    # only accepts canonical %Record{} values.
    with {:ok, record} <- RecordSource.from_storage_map(source_record),
         {:ok, full_path} <- RecordSource.resolve_path(record) do
      full_path
    else
      _ ->
        resolve_file_path(source_record["path"], get_in(source_record, ["attributes", "volume"]))
    end
  end

  defp resolve_file_path(%IngestJob{file_path: path, volume_name: volume_name}),
    do: resolve_file_path(path, volume_name)

  defp resolve_file_path(path, nil) do
    case FileExplorer.resolve_path(path) do
      {:ok, full_path} ->
        full_path

      _ ->
        path
    end
  end

  defp resolve_file_path(path, volume_name) do
    case FileExplorer.resolve_path(volume_name, path) do
      {:ok, full_path} -> full_path
      _ -> path
    end
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
