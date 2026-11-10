defmodule Zaq.Agent.Tools.SearchKnowledgeBaseModesTest do
  use Zaq.DataCase, async: true

  alias ReqLLM.RerankResponse
  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Event
  alias Zaq.Ingestion.Api
  alias Zaq.System.OperationModelConfig, as: RAGModelConfig
  alias Zaq.SystemConfigFixtures

  defmodule Router do
    def dispatch(%Event{opts: [{:action, :list_chunk_languages} | _]} = event),
      do: %{event | response: {:ok, ["simple"]}}

    def dispatch(%Event{request: %{access_opts: opts}} = event) do
      mode = opts[:search_mode]

      if event.actor && event.actor[:test_pid] do
        send(event.actor.test_pid, {:search_leg, mode, self()})
        if event.actor[:gate], do: receive(do: (:release -> :ok))
      end

      chunks =
        Enum.map(1..120, fn id ->
          %{
            "chunk_id" => id,
            "document_id" => 1,
            "chunk_index" => id,
            "section_path" => [],
            "content" => "chunk #{id}",
            "direct_match" => true,
            "vector_distance" => if(mode == :semantic, do: id / 1000),
            "bm25_score" => if(mode == :keyword, do: 121 - id),
            "retrieval_legs" => [if(mode == :semantic, do: "vector", else: "lexical")]
          }
        end)

      %{event | response: {:ok, chunks}}
    end

    def dispatch(%Event{opts: [{:action, action} | _]} = event),
      do: Api.handle_event(event, action, %{})
  end

  defmodule Reranker do
    def rerank(_model, opts) do
      results =
        opts[:documents]
        |> Enum.with_index()
        |> Enum.map(fn {_, index} -> %{index: index, relevance_score: index / 1000} end)

      {:ok, %RerankResponse{results: results}}
    end
  end

  defmodule FailingReranker do
    def rerank(_, _), do: {:error, :failed}
  end

  defmodule FailingKeywordRouter do
    def dispatch(%Event{request: %{access_opts: opts}} = event) do
      if opts[:search_mode] == :keyword,
        do: %{event | response: {:error, :keyword_unavailable}},
        else: Router.dispatch(event)
    end

    def dispatch(event), do: Router.dispatch(event)
  end

  defp context(extra) do
    Map.merge(
      %{
        node_router: Router,
        reranking_config: %RAGModelConfig{},
        context_window: %{max_context_tokens: 128_000}
      },
      extra
    )
  end

  test "hybrid is the default, shares one global cap, and starts both legs concurrently" do
    ctx = context(%{execution_actor: %{test_pid: self(), gate: true}})

    task =
      Task.async(fn ->
        Jido.Exec.run(SearchKnowledgeBase, %{query: "query", lexical_terms: ["term"]}, ctx)
      end)

    assert_receive {:search_leg, :semantic, semantic}, 5_000
    assert_receive {:search_leg, :keyword, keyword}, 5_000
    send(semantic, :release)
    send(keyword, :release)

    assert {:ok, %{count: 100, chunks: chunks, partial: false, errors: []}} =
             Task.await(task, 10_000)

    assert length(Enum.uniq_by(chunks, & &1["chunk_id"])) == 100
    assert Enum.all?(chunks, &is_number(&1["rrf_score"]))
  end

  test "semantic requires no lexical terms and never starts keyword retrieval or fusion" do
    assert {:ok, %{count: 3, chunks: chunks}} =
             Jido.Exec.run(
               SearchKnowledgeBase,
               %{query: "query", search_mode: "semantic", max_total_results: 3},
               context(%{execution_actor: %{test_pid: self()}})
             )

    assert_receive {:search_leg, :semantic, _}
    refute_receive {:search_leg, :keyword, _}
    assert Enum.map(chunks, & &1["chunk_id"]) == [1, 2, 3]
    assert Enum.all?(chunks, &is_nil(&1["rrf_score"]))
  end

  test "keyword starts no semantic retrieval and also skips fusion" do
    assert {:ok, %{count: 2, chunks: chunks}} =
             Jido.Exec.run(
               SearchKnowledgeBase,
               %{
                 query: "query",
                 lexical_terms: ["term"],
                 search_mode: "keyword",
                 max_total_results: 2
               },
               context(%{execution_actor: %{test_pid: self()}})
             )

    assert_receive {:search_leg, :keyword, _}
    refute_receive {:search_leg, :semantic, _}
    assert Enum.map(chunks, & &1["chunk_id"]) == [1, 2]
    assert Enum.all?(chunks, &is_nil(&1["rrf_score"]))
  end

  test "reranking sees all candidates before the global cap in every mode" do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{provider: "cohere", api_key: "test-key"})

    ctx =
      context(%{
        reranking_config: %RAGModelConfig{credential_id: credential.id, model: "rerank-v3.5"},
        reranker: Reranker
      })

    for mode <- ["semantic", "keyword", "hybrid"] do
      assert {:ok, %{chunks: ranked, count: 3}} =
               Jido.Exec.run(
                 SearchKnowledgeBase,
                 %{
                   query: "query",
                   lexical_terms: ["term"],
                   search_mode: mode,
                   max_total_results: 3
                 },
                 ctx
               )

      assert Enum.map(ranked, & &1["chunk_id"]) == [120, 119, 118]
    end

    assert {:error, _} =
             Jido.Exec.run(SearchKnowledgeBase, %{query: "query", lexical_terms: ["term"]}, %{
               ctx
               | reranker: FailingReranker
             })
  end

  test "invalid modes, maxima and keyword/hybrid clauses fail before discovery" do
    for params <- [
          %{search_mode: "bad"},
          %{max_total_results: 0},
          %{max_total_results: nil},
          %{search_mode: "keyword", lexical_terms: []},
          %{lexical_terms: ["   "]}
        ] do
      assert {:error, _} =
               Jido.Exec.run(
                 SearchKnowledgeBase,
                 Map.merge(%{query: "query", lexical_terms: ["term"]}, params),
                 context(%{execution_actor: %{test_pid: self()}})
               )
    end

    refute_receive {:search_leg, _, _}
  end

  test "a failed hybrid leg does not silently downgrade the language to semantic success" do
    ctx = context(%{node_router: FailingKeywordRouter})

    assert {:error, _} =
             Jido.Exec.run(SearchKnowledgeBase, %{query: "query", lexical_terms: ["term"]}, ctx)

    assert {:ok, %{count: 100}} =
             Jido.Exec.run(SearchKnowledgeBase, %{query: "query", search_mode: "semantic"}, ctx)
  end

  test "the overall deadline cancels blocked retrieval workers rather than leaving orphan requests" do
    ctx =
      context(%{
        execution_actor: %{test_pid: self(), gate: true},
        retrieval_deadline: System.monotonic_time(:millisecond) + 2_000
      })

    task =
      Task.async(fn ->
        SearchKnowledgeBase.run(%{query: "query", lexical_terms: ["term"]}, ctx)
      end)

    assert_receive {:search_leg, :semantic, semantic}, 1_500
    assert_receive {:search_leg, :keyword, keyword}, 1_500
    semantic_ref = Process.monitor(semantic)
    keyword_ref = Process.monitor(keyword)
    assert {:error, "Knowledge base search timed out"} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^semantic_ref, :process, ^semantic, _}, 2_000
    assert_receive {:DOWN, ^keyword_ref, :process, ^keyword, _}, 2_000
  end

  test "caller cancellation also terminates both active retrieval legs" do
    ctx = context(%{execution_actor: %{test_pid: self(), gate: true}})

    task =
      Task.async(fn ->
        SearchKnowledgeBase.run(%{query: "query", lexical_terms: ["term"]}, ctx)
      end)

    assert_receive {:search_leg, :semantic, semantic}, 2_000
    assert_receive {:search_leg, :keyword, keyword}, 2_000
    semantic_ref = Process.monitor(semantic)
    keyword_ref = Process.monitor(keyword)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^semantic_ref, :process, ^semantic, _}, 2_000
    assert_receive {:DOWN, ^keyword_ref, :process, ^keyword, _}, 2_000
  end
end
