defmodule Zaq.Ingestion.DocumentIngestionSummaryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Ingestion.{Chunk, DocumentIngestionSummary, IngestChunkJob}

  test "counts language-specific, simple and unindexed chunks without overlapping" do
    jobs = [
      job(1, "completed", "french"),
      job(2, "completed", "japanese"),
      job(3, "failed_final", "arabic", "Embedding failed"),
      job(4, "pending", "german")
    ]

    indexed = [
      %Chunk{chunk_index: 1, language: "french", metadata: %{"search_configuration" => "french"}},
      %Chunk{
        chunk_index: 2,
        language: "japanese",
        metadata: %{"search_configuration" => "simple"}
      }
    ]

    assert %{
             "total_chunks_detected" => 4,
             "total_chunks_indexed" => 2,
             "total_chunks_simple_indexed" => 1,
             "detected_languages" => ["arabic", "french", "german", "japanese"],
             "indexed_languages" => ["french", "japanese"],
             "errors" => [
               %{"chunk_index" => 3, "language" => "arabic", "message" => "Embedding failed"}
             ]
           } = DocumentIngestionSummary.build(jobs, indexed)
  end

  test "a retry clears a resolved failure without double-counting the chunk" do
    jobs = [job(1, "completed", "english")]

    chunks = [
      %Chunk{
        chunk_index: 1,
        language: "english",
        metadata: %{"search_configuration" => "english"}
      }
    ]

    assert %{"total_chunks_indexed" => 1, "total_chunks_simple_indexed" => 0, "errors" => []} =
             DocumentIngestionSummary.build(jobs, chunks ++ chunks)
  end

  property "simple-indexed is a subset of indexed, and indexed never exceeds detected" do
    check all(statuses <- list_of(member_of(~w(completed pending failed_final)), max_length: 35)) do
      jobs = for {status, index} <- Enum.with_index(statuses, 1), do: job(index, status, "urdu")

      chunks =
        for {status, index} <- Enum.with_index(statuses, 1), status == "completed" do
          %Chunk{
            chunk_index: index,
            language: "urdu",
            metadata: %{
              "search_configuration" => if(rem(index, 2) == 0, do: "simple", else: "urdu")
            }
          }
        end

      summary = DocumentIngestionSummary.build(jobs, chunks)

      assert 0 <= summary["total_chunks_simple_indexed"]
      assert summary["total_chunks_simple_indexed"] <= summary["total_chunks_indexed"]
      assert summary["total_chunks_indexed"] <= summary["total_chunks_detected"]
    end
  end

  defp job(index, status, language, error \\ nil) do
    %IngestChunkJob{
      chunk_index: index,
      status: status,
      chunk_payload: %{"language" => language},
      error: error
    }
  end
end
