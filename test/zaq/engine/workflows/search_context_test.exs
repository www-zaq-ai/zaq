defmodule Zaq.Engine.Workflows.SearchContextTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Engine.Workflows
  alias Zaq.Event
  alias Zaq.Ingestion.Api, as: IngestionApi

  @fixture_query "what can you tell me about clickcreate ?"
  @detailed_query "what can you tell me about clickcreate in detail ?"

  setup do
    Process.register(self(), __MODULE__)
    previous = Application.fetch_env(:zaq, :workflow_step_node_router)
    Application.put_env(:zaq, :workflow_step_node_router, __MODULE__)
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    on_exit(fn ->
      case previous do
        {:ok, router} -> Application.put_env(:zaq, :workflow_step_node_router, router)
        :error -> Application.delete_env(:zaq, :workflow_step_node_router)
      end
    end)
  end

  def dispatch(
        %Event{request: %{token_budget: budget, max_total_results: maximum, chunks: chunks}} =
          event
      ) do
    send(__MODULE__, {:result_limits, budget, maximum, length(chunks)})
    IngestionApi.handle_event(event, :limit_knowledge_results, nil)
  end

  def dispatch(%Event{request: %{semantic_chunks: chunks}} = event),
    do: %{event | response: {:ok, %{chunks: chunks}}}

  def dispatch(%Event{request: request} = event) when map_size(request) == 0,
    do: %{event | response: {:ok, ["simple"]}}

  def dispatch(%Event{request: %{query: query}} = event)
      when query in [@fixture_query, @detailed_query] do
    content =
      if query == @fixture_query,
        do: "ClickCreate result",
        else: String.duplicate("ClickCreate ", 100)

    chunks =
      for index <- 1..150 do
        %{
          "content" => "#{content} #{index}",
          "source" => "docs/clickcreate.md",
          "chunk_index" => index
        }
      end

    %{event | response: {:ok, chunks}}
  end

  def dispatch(%Event{request: %{query: _query}} = event),
    do: %{event | response: {:ok, []}}

  def dispatch(%Event{request: %{chunks: chunks}} = event),
    do: %{event | response: {:ok, chunks}}

  test "imported workflow caps short results at 100 with a 6400-token budget" do
    assert %{
             "count" => 100,
             "chunks" => chunks,
             "sources" => ["docs/clickcreate.md"],
             "errors" => [],
             "partial" => false
           } = run_imported_search(@fixture_query)

    assert length(chunks) == 100
    assert_received {:result_limits, 6_400, 100, 150}
  end

  test "the imported workflow token budget can bind before the result-count cap" do
    assert %{
             "count" => count,
             "chunks" => chunks,
             "sources" => ["docs/clickcreate.md"],
             "errors" => [],
             "partial" => false
           } = run_imported_search(@detailed_query)

    assert count in 1..99
    assert length(chunks) == count
    assert_received {:result_limits, 6_400, 100, 150}
  end

  defp run_imported_search(query) do
    params = %{
      "query" => query,
      "lexical_terms" => ["clickcreate", "click create"],
      "search_mode" => "hybrid",
      "max_total_results" => 100
    }

    {:ok, workflow} =
      Workflows.import_workflow(%{
        "name" => "ClickCreate — knowledge base search",
        "description" => "Search the knowledge base for information about ClickCreate.",
        "status" => "active",
        "settings" => %{"context_window" => %{"max_context_tokens" => 32_000}},
        "nodes" => [
          %{
            "name" => "search_clickcreate",
            "type" => "action",
            "module" => inspect(SearchKnowledgeBase),
            "params" => params,
            "index" => 0
          }
        ],
        "edges" => []
      })

    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => nil,
        "assigns" => %{},
        "trace_id" => Ecto.UUID.generate()
      })

    assert {:ok, %{status: "completed"}} = Workflows.start_run(run)
    assert [step] = Workflows.list_step_runs(run.id)
    assert step.step_name == "search_clickcreate"
    assert step.status == "completed"
    assert Map.take(step.input, Map.keys(params)) == params

    step.results
  end
end
