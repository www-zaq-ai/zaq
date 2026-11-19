defmodule Zaq.Engine.Workflows.SearchContextTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Event
  alias Zaq.Ingestion.Api, as: IngestionApi

  setup do
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
    send(event.actor.test_pid, {:result_limits, budget, maximum, length(chunks)})
    IngestionApi.handle_event(event, :limit_knowledge_results, nil)
  end

  def dispatch(%Event{request: %{semantic_chunks: chunks}} = event),
    do: %{event | response: {:ok, %{chunks: chunks}}}

  def dispatch(%Event{request: request} = event) when map_size(request) == 0,
    do: %{event | response: {:ok, ["simple"]}}

  def dispatch(%Event{request: %{query: query}} = event)
      when query in ["find elixir", "find detailed elixir"] do
    content =
      if query == "find elixir", do: "Elixir result", else: String.duplicate("Elixir ", 100)

    chunks =
      for index <- 1..150 do
        %{
          "content" => "#{content} #{index}",
          "source" => "docs/elixir.md",
          "chunk_index" => index
        }
      end

    %{event | response: {:ok, chunks}}
  end

  def dispatch(%Event{request: %{query: _query}} = event),
    do: %{event | response: {:ok, []}}

  def dispatch(%Event{request: %{chunks: chunks}} = event),
    do: %{event | response: {:ok, chunks}}

  test "direct workflow search caps short results at 100 with a 6400-token budget" do
    assert {:ok, %{count: 100, chunks: chunks, errors: [], partial: false}} =
             run_search("find elixir")

    assert length(chunks) == 100
    assert_received {:result_limits, 6_400, 100, 150}
  end

  test "the snapshotted token budget can bind before the result-count cap" do
    assert {:ok, %{count: count, chunks: chunks, errors: [], partial: false}} =
             run_search("find detailed elixir")

    assert count in 1..99
    assert length(chunks) == count
    assert_received {:result_limits, 6_400, 100, 150}
  end

  defp run_search(query) do
    alias Zaq.Engine.Workflows
    alias Zaq.Engine.Workflows.StepRunner

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Direct workflow search",
        status: "active",
        settings: %{"context_window" => %{"max_context_tokens" => 32_000}},
        nodes: [
          %{
            name: "search",
            type: "action",
            module: inspect(SearchKnowledgeBase),
            params: %{},
            index: 0
          }
        ],
        edges: []
      })

    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => nil,
        "assigns" => %{},
        "trace_id" => Ecto.UUID.generate()
      })

    StepRunner.run(
      %{
        wrapped_module: SearchKnowledgeBase,
        run_id: run.id,
        step_name: "search",
        step_index: 0,
        query: query,
        lexical_terms: ["test"],
        max_total_results: 100
      },
      %{execution_actor: %{test_pid: self()}}
    )
  end
end
