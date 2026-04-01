defmodule Zaq.Ingestion.IngestChunkWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :ingestion_chunks,
    max_attempts: 5,
    unique: [period: 120, fields: [:args]]

  alias Zaq.Engine.Telemetry
  alias Zaq.Ingestion.{DocumentChunker, IngestChunkJob, IngestJob, JobLifecycle}
  alias Zaq.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"chunk_job_id" => chunk_job_id, "job_id" => job_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    with %IngestJob{} = ingest_job <- Repo.get(IngestJob, job_id),
         %IngestChunkJob{} = chunk_job <- Repo.get(IngestChunkJob, chunk_job_id) do
      chunk_job = transition_chunk!(chunk_job, %{status: "processing", attempts: attempt})

      result = process_chunk(ingest_job, chunk_job)

      case result do
        :ok ->
          finalize_chunk_success(ingest_job, chunk_job)

        {:error, {:rate_limited, delay_seconds, _details}} ->
          transition_chunk!(chunk_job, %{status: "pending", error: "Rate limited (429), retrying"})

          Telemetry.record("ingestion.chunk.retry.count", 1, %{
            mode: ingest_job.mode,
            volume: ingest_job.volume_name || "default"
          })

          {:snooze, delay_seconds}

        {:error, reason} when attempt >= max_attempts ->
          finalize_chunk_final_failure(ingest_job, chunk_job, reason)

        {:error, reason} ->
          transition_chunk!(chunk_job, %{status: "pending", error: format_reason(reason)})

          Telemetry.record("ingestion.chunk.retry.count", 1, %{
            mode: ingest_job.mode,
            volume: ingest_job.volume_name || "default"
          })

          {:error, reason}
      end
    else
      nil -> {:cancel, :not_found}
    end
  end

  defp process_chunk(ingest_job, chunk_job) do
    processor = Application.get_env(:zaq, :document_processor, Zaq.Ingestion.DocumentProcessor)

    payload = chunk_job.chunk_payload || %{}

    chunk =
      struct(DocumentChunker.Chunk, %{
        id: Map.get(payload, "id"),
        section_id: Map.get(payload, "section_id"),
        content: Map.get(payload, "content", ""),
        section_path: Map.get(payload, "section_path", []),
        tokens: Map.get(payload, "tokens", 0),
        metadata: Map.get(payload, "metadata", %{})
      })

    case processor.store_chunk_with_metadata(
           chunk,
           ingest_job.document_id,
           chunk_job.chunk_index,
           ingest_job.role_id,
           ingest_job.shared_role_ids
         ) do
      {:ok, _chunk} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_chunk_success(ingest_job, chunk_job) do
    transition_chunk!(chunk_job, %{status: "completed", error: nil})
    maybe_finalize_job(ingest_job)
  end

  defp finalize_chunk_final_failure(ingest_job, chunk_job, reason) do
    transition_chunk!(chunk_job, %{status: "failed_final", error: format_reason(reason)})

    Telemetry.record("ingestion.chunk.failed.final.count", 1, %{
      mode: ingest_job.mode,
      volume: ingest_job.volume_name || "default"
    })

    maybe_finalize_job(ingest_job)
  end

  defp maybe_finalize_job(ingest_job) do
    total = IngestChunkJob.count_all(ingest_job.id)
    terminal = IngestChunkJob.count_terminal(ingest_job.id)
    completed = IngestChunkJob.count_completed(ingest_job.id)
    failed = IngestChunkJob.count_failed_final(ingest_job.id)
    failed_indices = IngestChunkJob.list_failed_final(ingest_job.id) |> Enum.map(& &1.chunk_index)

    attrs = %{
      total_chunks: total,
      ingested_chunks: completed,
      chunks_count: completed,
      failed_chunks: failed,
      failed_chunk_indices: failed_indices
    }

    if terminal == total and total > 0 do
      if failed == 0 do
        Telemetry.record("ingestion.completed.count", 1, %{
          mode: ingest_job.mode,
          volume: ingest_job.volume_name || "default"
        })

        Telemetry.record("ingestion.chunks.created", completed, %{
          mode: ingest_job.mode,
          volume: ingest_job.volume_name || "default"
        })

        JobLifecycle.mark_completed!(ingest_job, attrs)
      else
        Telemetry.record("ingestion.document.failed.final.count", 1, %{
          mode: ingest_job.mode,
          volume: ingest_job.volume_name || "default"
        })

        JobLifecycle.transition!(
          ingest_job,
          Map.merge(attrs, %{
            status: "completed_with_errors",
            completed_at: DateTime.utc_now(),
            error: "#{failed} chunks failed after retries"
          })
        )
      end
    else
      JobLifecycle.transition!(ingest_job, Map.merge(attrs, %{status: "processing"}))
    end

    :ok
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp transition_chunk!(chunk_job, attrs) do
    chunk_job
    |> IngestChunkJob.changeset(attrs)
    |> Repo.update!()
  end
end
