defmodule Zaq.Agent.Providers.ZAQRouterTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Providers.ZAQRouter
  alias Zaq.TestSupport.OpenAIStub

  @model LLMDB.Model.new!(%{
           provider: :zaq_router,
           id: "Qwen/Qwen3-Reranker-0.6B",
           capabilities: %{chat: false, rerank: true},
           execution: %{
             rerank: %{
               supported: true,
               family: "cohere_rerank_compatible",
               wire_protocol: "cohere_rerank",
               transport: "http",
               path: "/rerank",
               provider_model_id: "Qwen/Qwen3-Reranker-0.6B"
             }
           }
         })

  test "public evaluation uses declared System One metadata with gateway identity" do
    {:ok, model} = LLMDB.model(:zaq_router, "typesafe/jev-1.14")
    questions = %{refund: %{type: :boolean, instructions: "Is a refund requested?"}}

    for base <- ["https://router.example", "https://router.example/v1"] do
      adapter = fn request ->
        assert URI.to_string(request.url) == "https://router.example/v1/systemone"
        assert Req.Request.get_header(request, "authorization") == ["Bearer gateway-test-key"]
        body = Jason.decode!(request.body)
        assert body["model"] == "typesafe/jev-1.14"
        assert body["questions"]["refund"]["type"] == "noul"

        response =
          OpenAIStub.decision_response(%{
            "refund" => %{"type" => "noul", "noul" => 0.9}
          })

        {request, Req.Response.new(status: 200, body: response)}
      end

      assert {:ok, response} =
               ReqLLM.evaluate(model, "Refund me", questions,
                 api_key: "gateway-test-key",
                 base_url: base,
                 req_http_options: [adapter: adapter]
               )

      assert response.provider_meta.provider == :zaq_router
      assert response.object["refund"]["probability"] == 0.9
    end
  end

  test "reuses Cohere encoding and normalization with gateway authentication and path" do
    adapter = fn request ->
      assert URI.to_string(request.url) == "https://router.example/proxy/rerank"
      assert request.method == :post
      assert Req.Request.get_header(request, "authorization") == ["Bearer router-test-key"]

      assert Jason.decode!(request.body) == %{
               "model" => @model.id,
               "query" => "query",
               "documents" => ["first", "second"],
               "top_n" => 1
             }

      {request,
       Req.Response.new(
         status: 200,
         body: %{"results" => [%{"index" => 1, "relevance_score" => 0.9}]}
       )}
    end

    assert {:ok, response} =
             ReqLLM.rerank(@model,
               query: "query",
               documents: ["first", "second"],
               top_n: 1,
               api_key: "router-test-key",
               base_url: "https://router.example/proxy",
               req_http_options: [url: "/wrong-path", adapter: adapter]
             )

    assert response.model == @model.id
    assert response.results == [%{index: 1, relevance_score: 0.9, document: "second"}]
    assert @model.provider == :zaq_router
  end

  test "retains library batching, global indices and stable top-N for duplicate documents" do
    adapter = fn request ->
      body = Jason.decode!(request.body)
      refute Map.has_key?(body, "top_n")

      results =
        body["documents"]
        |> Enum.with_index()
        |> Enum.map(fn {_document, index} -> %{"index" => index, "relevance_score" => 0.5} end)

      {request, Req.Response.new(status: 200, body: %{"results" => results})}
    end

    assert {:ok, response} =
             ReqLLM.rerank(@model,
               query: "query",
               documents: ["same", "same", "third"],
               top_n: 2,
               batch_size: 2,
               api_key: "router-test-key",
               base_url: "https://router.example",
               req_http_options: [adapter: adapter]
             )

    assert Enum.map(response.results, & &1.index) == [0, 1]
  end

  test "provider errors and malformed success responses remain errors" do
    for {status, body} <- [{401, %{"error" => "denied"}}, {200, %{"unexpected" => []}}] do
      adapter = fn request -> {request, Req.Response.new(status: status, body: body)} end

      assert {:error, _} =
               ReqLLM.rerank(@model,
                 query: "query",
                 documents: ["first"],
                 api_key: "router-test-key",
                 base_url: "https://router.example",
                 req_http_options: [adapter: adapter]
               )
    end
  end

  test "other operations retain the standard ZAQ Router provider path" do
    model = LLMDB.Model.new!(%{provider: :zaq_router, id: "openai/gpt-oss-120b"})

    assert {:ok, request} =
             ZAQRouter.prepare_request(:chat, model, "hello",
               api_key: "router-test-key",
               base_url: "https://router.example"
             )

    assert URI.to_string(request.url) == "/chat/completions"
  end
end
