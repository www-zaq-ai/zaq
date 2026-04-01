defmodule Zaq.Ingestion.IngestChunkWorker do
  @moduledoc """
  Oban worker that processes a single persisted chunk ingestion job.

  This worker is the chunk-level execution unit for the async ingestion pipeline:

  - reads one `IngestChunkJob` payload,
  - generates chunk title + embedding + chunk insert via the configured document processor,
  - updates chunk-job status/retry state,
  - recomputes and updates parent `IngestJob` progress counters.

  Retries are handled by Oban. For rate-limit (`429`) errors, the worker returns
  `{:snooze, delay_seconds}` so retry delay follows provider headers when available.
  """

  use Oban.Worker,
    queue: :ingestion_chunks,
    max_attempts: 5,
    unique: [period: 120, fields: [:args]]

  import Ecto.Query

  alias Zaq.Engine.Telemetry
  alias Zaq.Ingestion.{DocumentChunker, IngestChunkJob, IngestJob, JobLifecycle}
  alias Zaq.Repo

  require Logger

  @terminal_job_statuses ["completed", "completed_with_errors", "failed"]

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
    Repo.transaction(fn ->
      locked_job =
        IngestJob
        |> where([j], j.id == ^ingest_job.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if locked_job.status in @terminal_job_statuses do
        :ok
      else
        snapshot = IngestChunkJob.finalization_snapshot(locked_job.id)

        attrs = %{
          total_chunks: snapshot.total,
          ingested_chunks: snapshot.completed,
          chunks_count: snapshot.completed,
          failed_chunks: snapshot.failed_final,
          failed_chunk_indices: snapshot.failed_chunk_indices
        }

        locked_job
        |> finalization_decision(snapshot)
        |> apply_finalization(locked_job, snapshot, attrs)
      end
    end)

    :ok
  end

  defp finalization_decision(_job, snapshot) do
    cond do
      snapshot.total == 0 -> :processing
      snapshot.terminal < snapshot.total -> :processing
      snapshot.failed_final == 0 -> :completed
      true -> :completed_with_errors
    end
  end

  defp apply_finalization(:processing, job, _snapshot, attrs) do
    JobLifecycle.transition!(job, Map.merge(attrs, %{status: "processing"}))
  end

  defp apply_finalization(:completed, job, snapshot, attrs) do
    Telemetry.record("ingestion.completed.count", 1, %{
      mode: job.mode,
      volume: job.volume_name || "default"
    })

    Telemetry.record("ingestion.chunks.created", snapshot.completed, %{
      mode: job.mode,
      volume: job.volume_name || "default"
    })

    JobLifecycle.mark_completed!(job, attrs)
  end

  defp apply_finalization(:completed_with_errors, job, snapshot, attrs) do
    Telemetry.record("ingestion.document.failed.final.count", 1, %{
      mode: job.mode,
      volume: job.volume_name || "default"
    })

    JobLifecycle.transition!(
      job,
      Map.merge(attrs, %{
        status: "completed_with_errors",
        completed_at: DateTime.utc_now(),
        error: "#{snapshot.failed_final} chunks failed after retries"
      })
    )
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
