defmodule Zaq.Agent.Actions.RerankKnowledgeResultsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias ReqLLM.RerankResponse
  alias Zaq.Agent.Actions.RerankKnowledgeResults
  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Engine.Connect
  alias Zaq.System.OperationModelConfig, as: RAGModelConfig
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

  defmodule MalformedClient do
    def rerank(_, _), do: {:ok, %RerankResponse{results: ["PRIVATE_PROVIDER_OUTPUT"]}}
  end

  defmodule RaisingClient do
    def rerank(_, _), do: raise("provider secret")
  end

  defmodule ErrorClient do
    alias ReqLLM.Error.API.Request, as: RequestError
    alias ReqLLM.Error.API.Timeout, as: TimeoutError

    def rerank(_, opts) do
      error =
        case String.split(opts[:query], ":", parts: 2) do
          ["http", status] ->
            RequestError.exception(
              status: String.to_integer(status),
              reason: "PRIVATE_REASON",
              response_body: %{"secret" => "PRIVATE_BODY"},
              headers: [{"authorization", "PRIVATE_TOKEN"}]
            )

          ["timeout", "total"] ->
            TimeoutError.exception(kind: :total, timeout: 1)

          ["timeout", "transport"] ->
            Req.TransportError.exception(reason: :timeout)

          ["error", private] ->
            private

          ["exception", private] ->
            RuntimeError.exception(private)

          ["status", private] ->
            RequestError.exception(
              status: private,
              reason: private,
              response_body: private
            )
        end

      {:error, error}
    end
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

  test "failure diagnostics identify runtime configuration and deadline stages" do
    assert {:error, error} =
             Jido.Exec.run(RerankKnowledgeResults, %{query: "query", chunks: [chunk(1)]}, %{
               reranking_config: %RAGModelConfig{model: "rerank-v3.5"}
             })

    assert error.message == "knowledge_reranking_failed: runtime/model_not_configured"

    context =
      configured(ReverseClient)
      |> Map.put(:retrieval_deadline, System.monotonic_time(:millisecond) - 1)

    assert {:error, error} =
             Jido.Exec.run(RerankKnowledgeResults, %{query: "query", chunks: [chunk(1)]}, context)

    assert error.message == "knowledge_reranking_failed: deadline/timeout"
  end

  test "invalid model contracts and malformed output retain safe diagnostic stages" do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{provider: "openai", api_key: "test-key"})

    assert {:error, error} =
             Jido.Exec.run(RerankKnowledgeResults, %{query: "query", chunks: [chunk(1)]}, %{
               reranking_config: %RAGModelConfig{
                 credential_id: credential.id,
                 model: "gpt-4.1-mini"
               }
             })

    assert error.message == "knowledge_reranking_failed: runtime/invalid_parameter"

    for {client, expected} <- [
          {InvalidClient, "response/invalid_response"},
          {MalformedClient, "response/invalid_response"},
          {RaisingClient, "request/unexpected_exception"}
        ] do
      assert {:error, error} =
               Jido.Exec.run(
                 RerankKnowledgeResults,
                 %{query: "query", chunks: [chunk(1)]},
                 configured(client)
               )

      assert error.message == "knowledge_reranking_failed: " <> expected
    end
  end

  test "revoked runtime authentication is diagnosed without credential or grant details" do
    context = configured(RaisingClient)
    credential = Zaq.System.get_ai_provider_credential(context.reranking_config.credential_id)

    assert {:ok, _} =
             Connect.revoke_credential_grant(credential.connect_credential_id, :org)

    assert {:error, error} =
             Jido.Exec.run(RerankKnowledgeResults, %{query: "query", chunks: [chunk(1)]}, context)

    assert error.message == "knowledge_reranking_failed: runtime/credential_revoked"
    refute inspect(error) =~ "credential_id"
    refute inspect(error) =~ "owner_type"
  end

  test "HTTP status and typed timeouts are retained without provider details" do
    context = configured(ErrorClient)

    for {status, category} <- [
          {401, :provider_authentication_failed},
          {403, :provider_authentication_failed},
          {429, :provider_rate_limited},
          {500, :provider_unavailable}
        ] do
      assert {:error, error} =
               Jido.Exec.run(
                 RerankKnowledgeResults,
                 %{query: "http:#{status}", chunks: [chunk(1)]},
                 context
               )

      assert error.message == "knowledge_reranking_failed: request/#{category} (HTTP #{status})"
      refute inspect(error) =~ "PRIVATE_"
    end

    for kind <- ["total", "transport"] do
      assert {:error, error} =
               Jido.Exec.run(
                 RerankKnowledgeResults,
                 %{query: "timeout:#{kind}", chunks: [chunk(1)]},
                 context
               )

      assert error.message == "knowledge_reranking_failed: request/timeout"
    end
  end

  test "real ReqLLM HTTP failures retain status without exposing the response body" do
    Req.Test.stub(HttpClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{message: "PRIVATE_PROVIDER_RESPONSE"}))
    end)

    assert {:error, error} =
             Jido.Exec.run(
               RerankKnowledgeResults,
               %{query: "question", chunks: [chunk(1)]},
               configured(HttpClient)
             )

    assert error.message ==
             "knowledge_reranking_failed: request/provider_authentication_failed (HTTP 401)"

    refute inspect(error) =~ "PRIVATE_PROVIDER_RESPONSE"
  end

  property "untrusted provider errors cannot enter returned errors or child trace evidence" do
    owner = self()

    context =
      configured(ErrorClient)
      |> Map.merge(%{
        tool_call_id: "reranking-diagnostics",
        on_tool_event: fn event -> send(owner, {:rerank_trace, event}) end
      })

    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 40), max_runs: 20) do
      private = "PRIVATE_ERROR_" <> suffix

      for kind <- ["error", "exception", "status"] do
        assert {:error, error} =
                 ActionContract.execute(
                   RerankKnowledgeResults,
                   %{query: "#{kind}:#{private}", chunks: [chunk(1)]},
                   context,
                   max_retries: 0
                 )

        category =
          if kind == "status", do: :provider_request_rejected, else: :agent_execution_failed

        assert error.message == "knowledge_reranking_failed: request/#{category}"
        assert_receive {:rerank_trace, %{kind: :tool_started}}
        assert_receive {:rerank_trace, %{kind: :tool_completed, data: data}}
        assert {:error, evidence, []} = data.result
        assert evidence.message == error.message
        refute inspect({error, data.result}) =~ private
      end
    end
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

  test "Albert catalog execution routes canonical and alias models through real ReqLLM" do
    {:ok, provider} = LLMDB.provider(:albert)

    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "albert",
        endpoint: provider.base_url,
        api_key: "test-albert-key"
      })

    Req.Test.stub(HttpClient, fn conn ->
      assert conn.host == "albert.api.etalab.gouv.fr"
      assert conn.request_path == "/v1/rerank"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-albert-key"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["model"] == "openweight-rerank"
      refute Map.has_key?(request, "temperature")
      refute Map.has_key?(request, "top_p")

      results =
        request["documents"]
        |> Enum.with_index()
        |> Enum.map(fn {text, index} ->
          assert text in ["content 1", "content 2", "content 3"]
          id = text |> String.split() |> List.last() |> String.to_integer()
          %{index: index, relevance_score: id / 10, document: %{text: "UNTRUSTED_ECHO"}}
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{results: results}))
    end)

    chunks = Enum.map(1..3, &chunk/1)
    denied = %{"document_id" => 9, "content" => "DENIED_CONTENT"}

    for id <- ["bge-reranker-v2-m3", "openweight-rerank"] do
      assert {:ok, %{chunks: [ranked_c, ^denied, ranked_b, ranked_a]}} =
               Jido.Exec.run(
                 RerankKnowledgeResults,
                 %{query: "question", chunks: List.insert_at(chunks, 1, denied)},
                 %{
                   reranking_config: %RAGModelConfig{credential_id: credential.id, model: id},
                   reranker: HttpClient
                 }
               )

      ranked = [ranked_c, ranked_b, ranked_a]
      assert Enum.map(ranked, &Map.delete(&1, "rerank_score")) == Enum.reverse(chunks)
      refute inspect(ranked) =~ "UNTRUSTED_ECHO"
    end
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
