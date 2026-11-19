defmodule Zaq.Engine.Workflows.SearchContextTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Event

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

  def dispatch(%Event{request: %{token_budget: budget, chunks: chunks}} = event) do
    send(event.actor.test_pid, {:result_budget, budget})
    %{event | response: {:ok, chunks}}
  end

  def dispatch(%Event{request: %{semantic_chunks: chunks}} = event),
    do: %{event | response: {:ok, %{chunks: chunks}}}

  def dispatch(%Event{request: request} = event) when map_size(request) == 0,
    do: %{event | response: {:ok, ["simple"]}}

  def dispatch(%Event{request: %{query: "find elixir"}} = event) do
    %{
      event
      | response:
          {:ok,
           [
             %{"content" => "Elixir runs on the BEAM VM.", "source" => "docs/elixir.md"},
             %{"content" => "It was created by José Valim."}
           ]}
    }
  end

  def dispatch(%Event{request: %{query: _query}} = event),
    do: %{event | response: {:ok, []}}

  def dispatch(%Event{request: %{chunks: chunks}} = event),
    do: %{event | response: {:ok, chunks}}

  test "direct workflow search uses the snapshotted capacity for its result budget" do
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

    assert {:ok, %{count: 2}} =
             StepRunner.run(
               %{
                 wrapped_module: SearchKnowledgeBase,
                 run_id: run.id,
                 step_name: "search",
                 step_index: 0,
                 query: "find elixir",
                 lexical_terms: ["test"],
                 max_total_results: 100
               },
               %{execution_actor: %{test_pid: self()}}
             )

    assert_received {:result_budget, 6_400}
  end
end
