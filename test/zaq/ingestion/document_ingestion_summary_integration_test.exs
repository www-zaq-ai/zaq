defmodule Zaq.Ingestion.DocumentIngestionSummaryIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Chunk, Document, DocumentIngestionSummary, IngestChunkJob, IngestJob}
  alias Zaq.Repo

  test "persists progress without losing unrelated document metadata and clears errors on retry" do
    Chunk.create_table(1536)

    {:ok, doc} =
      Document.create(%{
        source: "summary-#{System.unique_integer([:positive])}",
        metadata: %{"provider" => "disk"}
      })

    {:ok, job} =
      %IngestJob{}
      |> IngestJob.changeset(%{
        file_path: "summary.md",
        document_id: doc.id,
        status: "processing"
      })
      |> Repo.insert()

    {:ok, child} =
      %IngestChunkJob{}
      |> IngestChunkJob.changeset(%{
        ingest_job_id: job.id,
        document_id: doc.id,
        chunk_index: 1,
        chunk_payload: %{"language" => "urdu", "content" => "test"},
        status: "failed_final",
        error: "Embedding unavailable"
      })
      |> Repo.insert()

    assert :ok = DocumentIngestionSummary.refresh(job, new_run: true)

    assert %{
             "provider" => "disk",
             "ingestion" => %{
               "total_chunks_detected" => 1,
               "total_chunks_indexed" => 0,
               "total_errors" => 1
             }
           } =
             Repo.get!(Document, doc.id).metadata

    assert {:ok, _} =
             Chunk.create(%{
               document_id: doc.id,
               chunk_index: 1,
               content: "test",
               language: "urdu",
               metadata: %{"search_configuration" => "simple"}
             })

    child |> IngestChunkJob.changeset(%{status: "completed", error: nil}) |> Repo.update!()

    assert :ok = DocumentIngestionSummary.refresh(job)

    assert %{
             "ingestion" => %{
               "total_chunks_detected" => 1,
               "total_chunks_indexed" => 1,
               "total_chunks_simple_indexed" => 1,
               "errors" => []
             }
           } =
             Repo.get!(Document, doc.id).metadata
  end

  test "inline ingestion records fallback and failure then clears resolved retry errors" do
    Chunk.create_table(1536)

    {:ok, doc} =
      Document.create(%{source: "inline-summary-#{System.unique_integer([:positive])}"})

    chunks = [%{content: "Short fragment"}, %{content: "Another short fragment"}]

    assert {:ok, persisted} =
             Chunk.create(%{
               document_id: doc.id,
               chunk_index: 1,
               language: "simple",
               content: "Short fragment",
               metadata: %{"search_configuration" => "simple"}
             })

    assert :ok =
             DocumentIngestionSummary.refresh_inline(
               doc.id,
               chunks,
               [{1, {:ok, persisted}}, {2, {:error, :embedding_failed}}],
               true
             )

    assert %{
             "total_chunks_detected" => 2,
             "total_chunks_indexed" => 1,
             "total_chunks_simple_indexed" => 1,
             "total_errors" => 1
           } =
             Repo.get!(Document, doc.id).metadata["ingestion"]

    assert {:ok, retry_chunk} =
             Chunk.create(%{
               document_id: doc.id,
               chunk_index: 2,
               language: "simple",
               content: "Another short fragment",
               metadata: %{"search_configuration" => "simple"}
             })

    assert :ok =
             DocumentIngestionSummary.refresh_inline(
               doc.id,
               chunks,
               [{2, {:ok, retry_chunk}}],
               false
             )

    assert %{"total_chunks_indexed" => 2, "total_errors" => 0, "errors" => []} =
             Repo.get!(Document, doc.id).metadata["ingestion"]
  end
end
