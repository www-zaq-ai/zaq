defmodule Zaq.Ingestion.Agent do
  @moduledoc """
  Orchestrates the Jido-based ingestion pipeline for a single `IngestJob`.

  ## Execution modes

  The agent selects the pipeline automatically:

  - **`:full`** — default; runs all five actions end-to-end.
  - **`:upload_only`** — pass `upload_only: true`; stops after `ConvertToMarkdown`
    and sets job status to `converted`.  Used when a file has been uploaded but
    chunking/embedding is deferred to a later trigger.
  - **`:from_converted`** — auto-detected when a `.md` sidecar already exists for
    the file; skips `UploadFile` and `ConvertToMarkdown`, resumes from
    `ChunkDocument`.

  ## Usage

      # From IngestWorker (async, Oban-driven):
      Zaq.Ingestion.Agent.run(job)

      # Upload-only (store file + convert, defer ingestion):
      Zaq.Ingestion.Agent.run(job, upload_only: true)

  ## Action output chaining

  `Jido.Exec.Chain` merges each action's result map into the running params map,
  so every downstream action receives the accumulated state of all previous steps.
  """

  require Logger

  alias Jido.Exec.Chain
  alias Zaq.Engine.Telemetry
  alias Zaq.Ingestion.{FileExplorer, IngestJob, JobLifecycle, Plan, Sidecar}

  @doc """
  Runs the ingestion pipeline for `job`.

  Returns `{:ok, updated_job}` on success (including `completed_with_errors`)
  or `{:error, updated_job}` when the job failed entirely.
  """
  @spec run(IngestJob.t(), keyword()) :: {:ok, IngestJob.t()} | {:error, IngestJob.t()}
  def run(%IngestJob{} = job, opts \\ []) do
    upload_only = Keyword.get(opts, :upload_only, false)

    job = JobLifecycle.mark_processing!(job)
    # Resolve once for mode detection (sidecar check). The raw path + volume_name
    # are passed to UploadFile which performs its own validated resolution.
    resolved_for_mode = resolve_file_path(job.file_path, job.volume_name)
    mode = determine_mode(resolved_for_mode, upload_only)
    telemetry_dims = %{mode: job.mode, volume: job.volume_name || "default"}

    Logger.info("[Ingestion.Agent] job=#{job.id} mode=#{mode} file=#{job.file_path}")

    actions = Plan.chain(mode)
    initial_params = initial_params(mode, job.file_path, job.volume_name, resolved_for_mode)

    case Chain.chain(actions, initial_params, context: build_context(job), max_retries: 0) do
      {:ok, result} ->
        finalize_success(job, result, mode, telemetry_dims)

      {:error, reason} ->
        finalize_error(job, reason, telemetry_dims)
    end
  end

  # ---------------------------------------------------------------------------
  # Mode detection
  # ---------------------------------------------------------------------------

  defp determine_mode(_file_path, true), do: :upload_only

  defp determine_mode(file_path, _upload_only) do
    case Sidecar.sidecar_path_for(file_path) do
      nil -> :full
      md_path -> if File.exists?(md_path), do: :from_converted, else: :full
    end
  end

  # ---------------------------------------------------------------------------
  # Initial params per mode
  # ---------------------------------------------------------------------------

  # Full and upload-only start at UploadFile which performs its own path resolution.
  # Pass the raw file_path + volume_name so UploadFile can resolve and validate.
  defp initial_params(mode, file_path, volume_name, _resolved)
       when mode in [:full, :upload_only] do
    %{file_path: file_path, volume_name: volume_name}
  end

  # from_converted skips UploadFile; ChunkDocument receives the already-resolved path.
  defp initial_params(:from_converted, _file_path, _volume_name, resolved) do
    %{file_path: resolved}
  end

  # ---------------------------------------------------------------------------
  # Finalisation
  # ---------------------------------------------------------------------------

  defp finalize_success(job, result, :upload_only, _telemetry_dims) do
    Logger.info("[Ingestion.Agent] job=#{job.id} converted — awaiting ingestion trigger")
    attrs = if doc_id = Map.get(result, :document_id), do: %{document_id: doc_id}, else: %{}
    {:ok, JobLifecycle.mark_converted!(job, attrs)}
  end

  defp finalize_success(job, result, _mode, telemetry_dims) do
    ingested = Map.get(result, :ingested_count, 0)
    failed = Map.get(result, :failed_count, 0)

    Telemetry.record("ingestion.completed.count", 1, telemetry_dims)
    Telemetry.record("ingestion.chunks.created", ingested, telemetry_dims)

    attrs = %{
      chunks_count: ingested,
      total_chunks: ingested + failed,
      ingested_chunks: ingested,
      failed_chunks: failed,
      failed_chunk_indices: []
    }

    updated =
      if failed == 0 do
        JobLifecycle.mark_completed!(job, attrs)
      else
        Telemetry.record("ingestion.document.failed.final.count", 1, telemetry_dims)

        JobLifecycle.transition!(
          job,
          Map.merge(attrs, %{
            status: "completed_with_errors",
            completed_at: DateTime.utc_now(),
            error: "#{failed} chunk(s) failed to embed"
          })
        )
      end

    {:ok, updated}
  end

  defp finalize_error(job, reason, telemetry_dims) do
    error_msg = format_error(reason)
    Logger.error("[Ingestion.Agent] job=#{job.id} failed: #{error_msg}")
    Telemetry.record("ingestion.document.failed.final.count", 1, telemetry_dims)
    updated = JobLifecycle.mark_failed!(job, error_msg, completed: true)
    {:error, updated}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp resolve_file_path(path, nil) do
    if Path.type(path) == :absolute do
      path
    else
      case FileExplorer.resolve_path(path) do
        {:ok, full_path} -> full_path
        _ -> path
      end
    end
  end

  defp resolve_file_path(path, volume_name) do
    case FileExplorer.resolve_path(volume_name, path) do
      {:ok, full_path} -> full_path
      _ -> path
    end
  end

  defp build_context(%IngestJob{} = job) do
    %{job_id: job.id, mode: job.mode, volume: job.volume_name || "default"}
  end

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
