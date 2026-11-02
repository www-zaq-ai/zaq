defmodule Zaq.Agent.Actions.SemanticKnowledgeSearchTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Actions.SemanticKnowledgeSearch
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Event

  defmodule Router do
    def dispatch(%Event{request: %{query: query, access_opts: opts}} = event) do
      %{event | response: {:ok, [%{"query" => query, "opts" => Map.new(opts)}]}}
    end
  end

  test "semantic Action needs no lexical input and forwards trusted access without fusion" do
    assert {:ok, %{chunks: [chunk]}} =
             Jido.Exec.run(
               SemanticKnowledgeSearch,
               %{query: "a semantic question", language: "english"},
               %{
                 node_router: Router,
                 person_id: 42,
                 source_filter: ["knowledge"]
               }
             )

    assert chunk["query"] == "a semantic question"
    assert chunk["opts"][:search_mode] == :semantic
    assert chunk["opts"][:language] == "english"
    assert chunk["opts"][:unbounded]
    assert chunk["opts"][:person_id] == 42
    assert chunk["opts"][:skip_permissions] == false
    assert chunk["opts"][:source_filter] == ["knowledge"]
    assert :ok = Action.validate(SemanticKnowledgeSearch)
  end
end
