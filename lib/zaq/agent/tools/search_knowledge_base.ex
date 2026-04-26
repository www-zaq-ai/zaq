defmodule Zaq.Agent.Tools.SearchKnowledgeBase do
  @moduledoc """
  ReAct tool: searches the ZAQ knowledge base with a refined query.

  Delegates to `DocumentProcessor.query_extraction/2` via NodeRouter so the
  call always goes through the correct node for ingestion.
  """

  use Jido.Action,
    name: "search_knowledge_base",
    description: """
    Search the ZAQ knowledge base for relevant information.
    Use this when the context provided in the system prompt is insufficient
    to answer the question with confidence.
    """,
    schema: [
      query: [type: :string, required: true, doc: "The refined search query to look up"]
    ]

  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  def run(%{query: query}, context) do
    person_id = Map.get(context, :person_id)
    team_ids = Map.get(context, :team_ids, [])
    node_router_mod = Map.get(context, :node_router, NodeRouter)
    doc_proc_mod = Map.get(context, :document_processor, DocumentProcessor)

    # nil person_id should NEVER grant all permissions.
    # Admin access must be explicitly granted via skip_permissions: true in context.
    # If the query has no identified person and is not explicitly an admin,
    # return only public data (skip_permissions: false, person_id: nil).
    skip_permissions = Map.get(context, :skip_permissions, false)
    opts = [person_id: person_id, team_ids: team_ids, skip_permissions: skip_permissions]

    try do
      case node_router_mod.call(:ingestion, doc_proc_mod, :query_extraction, [query, opts]) do
        {:ok, chunks} ->
          formatted = Enum.map_join(chunks, "\n\n", &format_chunk/1)
          {:ok, %{chunks: formatted, count: length(chunks)}}

        {:error, reason} ->
          {:error, "Knowledge base search failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Knowledge base search error: #{Exception.message(e)}"}
    end
  end

  defp format_chunk(%{"content" => content, "source" => source}),
    do: "Source: #{source}\n#{content}"

  defp format_chunk(%{"content" => content}), do: content
end
