defmodule Zaq.Agent.Actions.KnowledgeSearch do
  @moduledoc """
  Shared trusted Ingestion dispatch boundary for internal retrieval Actions.

  This is not an Action or agent tool. It constructs read-only retrieval events
  without allowing model parameters to override actor, permissions or sources.
  """

  alias Zaq.Agent.KnowledgeAccess
  alias Zaq.Event
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  @doc "Executes one retrieval leg through Ingestion, deferring final answer limits."
  def search(query, params, context, mode) do
    access_opts =
      KnowledgeAccess.options(context) ++
        Enum.reject(
          [
            language: params[:language],
            lexical_terms: params[:lexical_terms],
            search_mode: mode,
            unbounded: true
          ],
          fn {_key, value} -> is_nil(value) end
        )

    router = Map.get(context, :node_router, NodeRouter)

    event =
      Event.new(%{query: query, access_opts: access_opts}, :ingestion,
        actor: context[:actor],
        opts: [
          action: :search_knowledge_base,
          document_processor: Map.get(context, :document_processor, DocumentProcessor)
        ]
      )

    case router.dispatch(event).response do
      {:ok, chunks} when is_list(chunks) -> {:ok, %{chunks: chunks}}
      {:error, _} = error -> error
    end
  end
end
