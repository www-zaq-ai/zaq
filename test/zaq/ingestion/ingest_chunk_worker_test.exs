defmodule Zaq.Ingestion.IngestChunkWorkerTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Document, IngestChunkJob, IngestChunkWorker, IngestJob}
  alias Zaq.Repo

  defmodule RateLimitProcessor do
    def store_chunk_with_metadata(_chunk, _document_id, _chunk_index) do
      {:error, {:rate_limited, 42, %{status: 429}}}
    end
  end

  defmodule SuccessProcessor do
    def store_chunk_with_metadata(_chunk, _document_id, _chunk_index) do
      {:ok, %{id: 1}}
    end
  end

  defmodule FailingProcessor do
    def store_chunk_with_metadata(_chunk, _document_id, _chunk_index) do
      {:error, :boom}
    end
  end

  setup do
    original_processor = Application.get_env(:zaq, :document_processor)

    on_exit(fn ->
      if is_nil(original_processor) do
        Application.delete_env(:zaq, :document_processor)
      else
        Application.put_env(:zaq, :document_processor, original_processor)
      end
    end)

    :ok
  end

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/chunk-worker.md", status: "processing", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  defp create_chunk_job(job, attrs) do
    %IngestChunkJob{}
    |> IngestChunkJob.changeset(
      Map.merge(
        %{
          ingest_job_id: job.id,
          document_id: 123,
          chunk_index: 1,
          chunk_payload: %{"id" => "chunk-1", "content" => "chunk content", "metadata" => %{}},
          status: "pending"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp create_document(attrs \\ %{}) do
    default = %{
      source: "chunk-worker-#{System.unique_integer([:positive])}.md",
      content: "# Test"
    }

    %Document{}
    |> Document.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  test "snoozes using rate_limited delay and keeps chunk pending" do
    Application.put_env(:zaq, :document_processor, RateLimitProcessor)

    job = create_job()
    document = create_document()
    chunk_job = create_chunk_job(job, %{document_id: document.id})

    assert {:snooze, 42} =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => chunk_job.id, "job_id" => job.id},
               attempt: 1,
               max_attempts: 5
             })

    refreshed_chunk_job = Repo.get!(IngestChunkJob, chunk_job.id)
    assert refreshed_chunk_job.status == "pending"
    assert refreshed_chunk_job.attempts == 1
    assert refreshed_chunk_job.error == "Rate limited (429), retrying"
  end

  test "does not reopen parent when job is already terminal" do
    Application.put_env(:zaq, :document_processor, SuccessProcessor)

    completed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    job =
      create_job(%{
        status: "completed",
        completed_at: completed_at,
        total_chunks: 1,
        ingested_chunks: 1,
        chunks_count: 1
      })

    document = create_document()
    chunk_job = create_chunk_job(job, %{document_id: document.id})

    assert :ok =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => chunk_job.id, "job_id" => job.id},
               attempt: 1,
               max_attempts: 5
             })

    refreshed_job = Repo.get!(IngestJob, job.id)
    refreshed_chunk_job = Repo.get!(IngestChunkJob, chunk_job.id)

    assert refreshed_job.status == "completed"
    assert DateTime.compare(refreshed_job.completed_at, completed_at) == :eq
    assert refreshed_chunk_job.status == "completed"
  end

  test "cancels when parent ingest job is missing" do
    assert {:cancel, :not_found} =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => Ecto.UUID.generate(), "job_id" => Ecto.UUID.generate()},
               attempt: 1,
               max_attempts: 5
             })
  end

  test "cancels when chunk job is missing" do
    job = create_job()

    assert {:cancel, :not_found} =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => Ecto.UUID.generate(), "job_id" => job.id},
               attempt: 1,
               max_attempts: 5
             })
  end

  test "keeps chunk pending and returns error for non-rate-limit retries" do
    Application.put_env(:zaq, :document_processor, FailingProcessor)

    job = create_job()
    document = create_document()
    chunk_job = create_chunk_job(job, %{document_id: document.id})

    assert {:error, :boom} =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => chunk_job.id, "job_id" => job.id},
               attempt: 1,
               max_attempts: 5
             })

    refreshed_chunk_job = Repo.get!(IngestChunkJob, chunk_job.id)
    refreshed_job = Repo.get!(IngestJob, job.id)

    assert refreshed_chunk_job.status == "pending"
    assert refreshed_chunk_job.attempts == 1
    assert refreshed_chunk_job.error == "boom"
    assert refreshed_job.status == "processing"
  end

  test "marks chunk failed_final and finalizes job with errors on last attempt" do
    Application.put_env(:zaq, :document_processor, FailingProcessor)

    job = create_job(%{status: "processing"})
    document = create_document()
    chunk_job = create_chunk_job(job, %{document_id: document.id, chunk_index: 1})

    assert :ok =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => chunk_job.id, "job_id" => job.id},
               attempt: 5,
               max_attempts: 5
             })

    refreshed_chunk_job = Repo.get!(IngestChunkJob, chunk_job.id)
    refreshed_job = Repo.get!(IngestJob, job.id)

    assert refreshed_chunk_job.status == "failed_final"
    assert refreshed_chunk_job.attempts == 5
    assert refreshed_chunk_job.error == "boom"

    assert refreshed_job.status == "completed_with_errors"
    assert refreshed_job.total_chunks == 1
    assert refreshed_job.ingested_chunks == 0
    assert refreshed_job.failed_chunks == 1
    assert refreshed_job.failed_chunk_indices == [1]
    assert refreshed_job.error =~ "1 chunks failed after retries"
    assert refreshed_job.completed_at != nil
  end

  test "keeps parent job in processing state when not all chunk jobs are terminal" do
    Application.put_env(:zaq, :document_processor, SuccessProcessor)

    job = create_job(%{status: "processing"})
    document = create_document()

    first_chunk =
      create_chunk_job(job, %{document_id: document.id, chunk_index: 1, status: "pending"})

    _second_chunk =
      create_chunk_job(job, %{document_id: document.id, chunk_index: 2, status: "pending"})

    assert :ok =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => first_chunk.id, "job_id" => job.id},
               attempt: 1,
               max_attempts: 5
             })

    refreshed_job = Repo.get!(IngestJob, job.id)
    refreshed_first_chunk = Repo.get!(IngestChunkJob, first_chunk.id)

    assert refreshed_job.status == "processing"
    assert refreshed_job.total_chunks == 2
    assert refreshed_job.ingested_chunks == 1
    assert refreshed_job.chunks_count == 1
    assert refreshed_job.failed_chunks == 0
    assert refreshed_first_chunk.status == "completed"
  end

  test "marks parent job completed when all chunk jobs complete successfully" do
    Application.put_env(:zaq, :document_processor, SuccessProcessor)

    job = create_job(%{status: "processing"})
    document = create_document()
    chunk_job = create_chunk_job(job, %{document_id: document.id, chunk_index: 1})

    assert :ok =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => chunk_job.id, "job_id" => job.id},
               attempt: 1,
               max_attempts: 5
             })

    refreshed_job = Repo.get!(IngestJob, job.id)

    assert refreshed_job.status == "completed"
    assert refreshed_job.total_chunks == 1
    assert refreshed_job.ingested_chunks == 1
    assert refreshed_job.chunks_count == 1
    assert refreshed_job.failed_chunks == 0
    assert refreshed_job.completed_at != nil
  end

  test "marks parent job completed_with_errors when all chunks are terminal but some failed" do
    Application.put_env(:zaq, :document_processor, SuccessProcessor)

    job = create_job(%{status: "processing"})
    document = create_document()

    pending_chunk =
      create_chunk_job(job, %{document_id: document.id, chunk_index: 1, status: "pending"})

    _failed_chunk =
      create_chunk_job(job, %{
        document_id: document.id,
        chunk_index: 2,
        status: "failed_final",
        attempts: 5,
        error: "previous failure"
      })

    assert :ok =
             IngestChunkWorker.perform(%Oban.Job{
               args: %{"chunk_job_id" => pending_chunk.id, "job_id" => job.id},
               attempt: 1,
               max_attempts: 5
             })

    refreshed_job = Repo.get!(IngestJob, job.id)

    assert refreshed_job.status == "completed_with_errors"
    assert refreshed_job.total_chunks == 2
    assert refreshed_job.ingested_chunks == 1
    assert refreshed_job.chunks_count == 1
    assert refreshed_job.failed_chunks == 1
    assert refreshed_job.failed_chunk_indices == [2]
    assert refreshed_job.error =~ "1 chunks failed after retries"
    assert refreshed_job.completed_at != nil
  end
end
