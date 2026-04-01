defmodule Zaq.Ingestion.IngestChunkJobTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.{Document, IngestChunkJob, IngestJob}
  alias Zaq.Repo

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/chunk-job.md", status: "processing", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  defp create_document(attrs \\ %{}) do
    default = %{source: "chunk-job-#{System.unique_integer([:positive])}.md", content: "# Test"}

    %Document{}
    |> Document.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  defp create_chunk_job(job, document, chunk_index, status) do
    %IngestChunkJob{}
    |> IngestChunkJob.changeset(%{
      ingest_job_id: job.id,
      document_id: document.id,
      chunk_index: chunk_index,
      chunk_payload: %{"content" => "chunk #{chunk_index}", "metadata" => %{}},
      status: status,
      attempts: 0
    })
    |> Repo.insert!()
  end

  test "finalization_snapshot/1 returns consistent aggregate counts and failed indices" do
    job = create_job()
    document = create_document()

    create_chunk_job(job, document, 1, "completed")
    create_chunk_job(job, document, 2, "failed_final")
    create_chunk_job(job, document, 3, "processing")
    create_chunk_job(job, document, 4, "failed_final")

    snapshot = IngestChunkJob.finalization_snapshot(job.id)

    assert snapshot.total == 4
    assert snapshot.terminal == 3
    assert snapshot.completed == 1
    assert snapshot.failed_final == 2
    assert snapshot.failed_chunk_indices == [2, 4]
  end
end
