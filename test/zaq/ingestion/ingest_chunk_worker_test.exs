defmodule Zaq.Ingestion.IngestChunkWorkerTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Document, IngestChunkJob, IngestChunkWorker, IngestJob}
  alias Zaq.Repo

  defmodule RateLimitProcessor do
    def store_chunk_with_metadata(_chunk, _document_id, _chunk_index, _role_id, _shared_role_ids) do
      {:error, {:rate_limited, 42, %{status: 429}}}
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
end
