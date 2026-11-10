defmodule Zaq.Agent.Actions.KeywordKnowledgeSearch do
  @moduledoc """
  Composable keyword-only knowledge retrieval through the Ingestion role.
  Preserves backend lexical clauses and access filters without embedding,
  vector retrieval, fusion, re-ranking or final answer limiting.
  """

  use Zaq.Engine.Workflows.Action,
    name: "keyword_knowledge_search",
    description: "Retrieve direct knowledge chunks by independent lexical clauses",
    schema:
      Zoi.object(%{
        lexical_terms: Zoi.list(Zoi.string() |> Zoi.min(1)) |> Zoi.min(1),
        language: Zoi.string() |> Zoi.optional()
      }),
    output_schema: Zoi.object(%{chunks: Zoi.list(Zoi.map())})

  alias Zaq.Agent.Actions.KnowledgeSearch

  @impl Jido.Action
  def run(%{lexical_terms: terms} = params, context) do
    terms = terms |> Enum.map(&String.trim/1) |> Enum.uniq()

    if Enum.any?(terms, &(&1 == "")) do
      {:error, :invalid_lexical_terms}
    else
      KnowledgeSearch.search("", %{params | lexical_terms: terms}, context, :keyword)
    end
  end
end
