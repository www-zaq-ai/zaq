defmodule Zaq.Agent.Actions.RerankKnowledgeResultsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias ReqLLM.RerankResponse
  alias Zaq.Agent.Actions.RerankKnowledgeResults
  alias Zaq.System.RAGModelConfig
  alias Zaq.SystemConfigFixtures

  defmodule ReverseClient do
    def rerank(_model, opts) do
      results =
        opts[:documents]
        |> Enum.with_index()
        |> Enum.map(fn {_, i} -> %{index: i, relevance_score: i / 10} end)

      {:ok, %RerankResponse{results: Enum.reverse(results)}}
    end
  end

  defmodule FailureClient do
    def rerank(_, _), do: {:error, "private provider credentials"}
  end

  defmodule InvalidClient do
    def rerank(_, _), do: {:ok, %RerankResponse{results: [%{index: 10, relevance_score: 1.0}]}}
  end

  defmodule RaisingClient do
    def rerank(_, _), do: raise("provider secret")
  end

  defmodule HttpClient do
    def rerank(model, opts) do
      ReqLLM.rerank(
        model,
        Keyword.merge(opts, batch_size: 2, req_http_options: [plug: {Req.Test, __MODULE__}])
      )
    end
  end

  defmodule DuplicateClient do
    def rerank(_, _),
      do:
        {:ok,
         %RerankResponse{
           results: [%{index: 0, relevance_score: 0.9}, %{index: 0, relevance_score: 0.8}]
         }}
  end

  defp configured(client) do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{provider: "cohere", api_key: "test-key"})

    %{
      reranking_config: %RAGModelConfig{credential_id: credential.id, model: "rerank-v3.5"},
      reranker: client
    }
  end

  defp chunk(id),
    do: %{
      "chunk_id" => id,
      "content" => "content #{id}",
      "metadata" => %{"id" => id},
      "direct_match" => true
    }

  property "unconfigured reranking is exact identity without adding scores" do
    check all(ids <- uniq_list_of(integer(1..1_000_000), max_length: 30)) do
      chunks = Enum.map(ids, &chunk/1)

      assert {:ok, %{chunks: ^chunks}} =
               Jido.Exec.run(RerankKnowledgeResults, %{query: "query", chunks: chunks}, %{
                 reranking_config: %RAGModelConfig{},
                 reranker: RaisingClient
               })
    end
  end

  test "maps model indexes back to unchanged metadata and skips denied placeholders" do
    denied = %{"content" => "You don't have access to this chunk.", "document_id" => 8}
    a = chunk(1)
    b = chunk(2)

    assert {:ok, %{chunks: [ranked_b, ^denied, ranked_a]}} =
             Jido.Exec.run(
               RerankKnowledgeResults,
               %{query: "question", chunks: [a, denied, b]},
               configured(ReverseClient)
             )

    assert Map.delete(ranked_b, "rerank_score") == b
    assert Map.delete(ranked_a, "rerank_score") == a
    assert ranked_b["rerank_score"] > ranked_a["rerank_score"]
  end

  test "configured errors, malformed output, timeout and exceptions are sanitized hard failures" do
    for client <- [FailureClient, InvalidClient, RaisingClient] do
      assert {:error, error} =
               Jido.Exec.run(
                 RerankKnowledgeResults,
                 %{query: "query", chunks: [chunk(1)]},
                 configured(client)
               )

      refute inspect(error) =~ "secret"
      refute inspect(error) =~ "credentials"
      assert inspect(error) =~ "knowledge_reranking_failed"
    end

    context =
      configured(ReverseClient)
      |> Map.put(:retrieval_deadline, System.monotonic_time(:millisecond) - 1)

    assert {:error, _} =
             Jido.Exec.run(RerankKnowledgeResults, %{query: "query", chunks: [chunk(1)]}, context)
  end

  test "duplicate and incomplete model indexes fail rather than dropping or repeating content" do
    assert {:error, _} =
             Jido.Exec.run(
               RerankKnowledgeResults,
               %{query: "query", chunks: [chunk(1), chunk(2)]},
               configured(DuplicateClient)
             )
  end

  test "real ReqLLM reranking batches HTTP requests and preserves original global indexes" do
    Req.Test.stub(HttpClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"documents" => documents} = Jason.decode!(body)

      results =
        documents
        |> Enum.with_index()
        |> Enum.map(fn {text, index} ->
          id = text |> String.split() |> List.last() |> String.to_integer()
          %{index: index, relevance_score: id / 10}
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{results: results}))
    end)

    chunks = Enum.map(1..5, &chunk/1)

    assert {:ok, %{chunks: ranked}} =
             Jido.Exec.run(
               RerankKnowledgeResults,
               %{query: "question", chunks: chunks},
               configured(HttpClient)
             )

    assert Enum.map(ranked, & &1["chunk_id"]) == [5, 4, 3, 2, 1]
    assert Enum.map(ranked, &Map.delete(&1, "rerank_score")) == Enum.reverse(chunks)
  end

  test "a partial configuration is not treated as an unconfigured no-op" do
    assert {:error, _} =
             Jido.Exec.run(RerankKnowledgeResults, %{query: "query", chunks: [chunk(1)]}, %{
               reranking_config: %RAGModelConfig{model: "rerank-v3.5"}
             })
  end

  test "empty candidates do not invoke inference" do
    assert {:ok, %{chunks: []}} =
             Jido.Exec.run(
               RerankKnowledgeResults,
               %{query: "query", chunks: []},
               configured(RaisingClient)
             )
  end
end
