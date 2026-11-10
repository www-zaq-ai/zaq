defmodule Zaq.Ingestion.E2ERetrievalFakeContractTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Actions.FuseKnowledgeResults
  alias Zaq.E2E.DocumentProcessorFake
  alias Zaq.Ingestion.{Chunk, Document}

  test "the E2E fake supplies persisted identities and ranked leg data to actual fusion" do
    Chunk.create_table(1536)

    {:ok, document} =
      Document.upsert(%{source: "e2e-contract.md", content: "uniquecontractneedle evidence"})

    {:ok, stored} =
      Chunk.create(%{
        document_id: document.id,
        chunk_index: 1,
        content: document.content,
        section_path: []
      })

    assert {:ok, [lexical]} =
             DocumentProcessorFake.query_extraction("",
               search_mode: :keyword,
               lexical_terms: ["uniquecontractneedle"],
               skip_permissions: true
             )

    assert lexical["chunk_id"] == stored.id
    assert lexical["document_id"] == document.id
    assert lexical["chunk_index"] == 1
    assert lexical["section_path"] == []
    assert is_number(lexical["bm25_score"])

    assert {:ok, [vector]} =
             DocumentProcessorFake.query_extraction("uniquecontractneedle",
               search_mode: :semantic,
               skip_permissions: true
             )

    assert vector["chunk_id"] == stored.id
    assert is_number(vector["vector_distance"])

    assert {:ok, %{chunks: [fused]}} =
             Jido.Exec.run(
               FuseKnowledgeResults,
               %{keyword_chunks: [lexical], semantic_chunks: [vector]},
               %{}
             )

    assert fused["chunk_id"] == stored.id
    assert is_number(fused["rrf_score"])
    assert DocumentProcessorFake.limit_chunks([lexical, vector], 1) == [lexical]
  end
end
