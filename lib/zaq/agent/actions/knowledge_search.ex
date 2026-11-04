defmodule Zaq.Agent.Actions.KnowledgeSearch do
  @moduledoc """
  Shared trusted Ingestion dispatch boundary for internal retrieval Actions.

  This is not an Action or agent tool. It constructs read-only retrieval events
  without allowing model parameters to override actor, permissions or sources.
  """

  alias Zaq.Event
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  @doc "Executes one retrieval leg through Ingestion, deferring final answer limits."
  def search(query, params, context, mode) do
    access_opts =
      [
        person_id: context[:person_id],
        team_ids: Map.get(context, :team_ids, []),
        skip_permissions: Map.get(context, :skip_permissions, false),
        source_filter: context[:source_filter],
        language: params[:language],
        lexical_terms: params[:lexical_terms],
        search_mode: mode,
        unbounded: true
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    router = Map.get(context, :node_router, NodeRouter)

    event =
      Event.new(%{query: query, access_opts: access_opts}, :ingestion,
        actor: context[:execution_actor],
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
