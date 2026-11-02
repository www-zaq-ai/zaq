defmodule Zaq.Agent.Actions.KeywordKnowledgeSearchTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Actions.KeywordKnowledgeSearch
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Event

  defmodule Router do
    def dispatch(%Event{request: %{access_opts: opts}} = event) do
      %{event | response: {:ok, [%{"opts" => Map.new(opts)}]}}
    end
  end

  test "keyword Action preserves independent clauses and trusted access without vectors" do
    terms = Enum.map(1..10, &"identifier #{&1}")

    assert {:ok, %{chunks: [chunk]}} =
             Jido.Exec.run(KeywordKnowledgeSearch, %{lexical_terms: terms}, %{node_router: Router})

    assert chunk["opts"][:lexical_terms] == terms
    assert chunk["opts"][:search_mode] == :keyword
    assert chunk["opts"][:skip_permissions] == false
    assert :ok = Action.validate(KeywordKnowledgeSearch)
  end

  test "empty and blank lexical clauses fail" do
    for terms <- [[], [""], ["   "], [1]] do
      assert {:error, _} =
               Jido.Exec.run(KeywordKnowledgeSearch, %{lexical_terms: terms}, %{
                 node_router: Router
               })
    end
  end
end
