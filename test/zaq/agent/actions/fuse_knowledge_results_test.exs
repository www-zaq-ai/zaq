defmodule Zaq.Agent.Actions.FuseKnowledgeResultsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.Actions.FuseKnowledgeResults
  alias Zaq.Event
  alias Zaq.Ingestion.Api

  defmodule Router do
    def dispatch(%Event{} = event), do: Api.handle_event(event, :fuse_knowledge_results, %{})
  end

  defp chunk(id) do
    %{
      "chunk_id" => id,
      "document_id" => 1,
      "chunk_index" => id,
      "section_path" => ["same"],
      "content" => "chunk #{id}",
      "direct_match" => true
    }
  end

  test "reuses weighted RRF by chunk, preserving raw scores and overlap evidence" do
    lexical = [Map.put(chunk(1), "bm25_score", 1.0), Map.put(chunk(2), "bm25_score", 0.8)]

    semantic = [
      Map.put(chunk(2), "vector_distance", 0.1),
      Map.put(chunk(3), "vector_distance", 0.2)
    ]

    assert {:ok, %{chunks: [overlap | rest]}} =
             Jido.Exec.run(
               FuseKnowledgeResults,
               %{keyword_chunks: lexical, semantic_chunks: semantic},
               %{node_router: Router}
             )

    assert overlap["chunk_id"] == 2
    assert overlap["retrieval_legs"] == ["lexical", "vector"]
    assert overlap["bm25_score"] == 0.8
    assert overlap["vector_distance"] == 0.1
    weights = Zaq.System.get_llm_config()

    assert_in_delta overlap["rrf_score"],
                    weights.fusion_bm25_weight / 62 + weights.fusion_vector_weight / 61,
                    1.0e-10

    assert Enum.map(rest, & &1["chunk_id"]) |> Enum.sort() == [1, 3]
  end

  property "fusion returns each identity once even with repeated input candidates" do
    check all(ids <- list_of(integer(1..100), max_length: 30)) do
      candidates = Enum.map(ids, &chunk/1)

      assert {:ok, %{chunks: result}} =
               Jido.Exec.run(
                 FuseKnowledgeResults,
                 %{keyword_chunks: candidates, semantic_chunks: candidates},
                 %{node_router: Router}
               )

      assert length(result) == length(Enum.uniq(ids))
      assert Enum.map(result, & &1["chunk_id"]) |> Enum.sort() == Enum.sort(Enum.uniq(ids))
    end
  end

  test "denied placeholders never acquire navigation IDs or model-eligible evidence" do
    denied = %{
      "document_id" => 9,
      "chunk_index" => 1,
      "section_path" => [],
      "content" => "denied"
    }

    assert {:ok, %{chunks: [result]}} =
             Jido.Exec.run(
               FuseKnowledgeResults,
               %{keyword_chunks: [denied], semantic_chunks: [denied]},
               %{node_router: Router}
             )

    assert result["content"] == "denied"
    refute Map.has_key?(result, "chunk_id")
    refute Map.has_key?(result, "vector_distance")
    refute Map.has_key?(result, "retrieval_legs")
    assert is_number(result["rrf_score"])
  end

  test "invalid identities fail instead of merging unrelated chunks" do
    assert {:error, _} =
             Jido.Exec.run(
               FuseKnowledgeResults,
               %{keyword_chunks: [%{"content" => "no identity"}], semantic_chunks: []},
               %{node_router: Router}
             )
  end
end
