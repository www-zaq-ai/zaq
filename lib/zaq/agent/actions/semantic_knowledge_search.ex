defmodule Zaq.Agent.Actions.SemanticKnowledgeSearch do
  @moduledoc """
  Composable vector-only knowledge retrieval through the Ingestion role.
  Uses existing embeddings, cosine threshold and access/source/language filters;
  it performs neither keyword search nor fusion, re-ranking or final limiting.
  """

  use Zaq.Engine.Workflows.Action,
    name: "semantic_knowledge_search",
    description: "Retrieve direct knowledge chunks by vector similarity",
    schema:
      Zoi.object(%{
        query: Zoi.string() |> Zoi.min(1),
        language: Zoi.string() |> Zoi.optional()
      }),
    output_schema: Zoi.object(%{chunks: Zoi.list(Zoi.map())})

  alias Zaq.Agent.Actions.KnowledgeSearch

  @impl Jido.Action
  def run(%{query: query} = params, context) do
    KnowledgeSearch.search(query, params, context, :semantic)
  end
end
