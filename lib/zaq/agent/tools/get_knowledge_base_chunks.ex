defmodule Zaq.Agent.Tools.GetKnowledgeBaseChunks do
  @moduledoc """
  Retrieves one or multiple exact knowledge chunks through the Ingestion role.

  Trusted execution context supplies access restrictions. A chunk ID never grants
  access: Ingestion rechecks current document permissions for every request.
  """

  use Zaq.Engine.Workflows.Action,
    name: "get_knowledge_base_chunks",
    description: """
    Fetch one or multiple knowledge chunks by ID. Use chunk_id, previous_chunk_id
    or next_chunk_id from search results to obtain surrounding context explicitly.
    Returns only the requested accessible chunks, in requested order; missing or
    inaccessible IDs are unavailable. Does not search or expand neighbors.
    """,
    schema:
      Zoi.object(%{
        chunk_ids: Zoi.list(Zoi.integer() |> Zoi.positive()) |> Zoi.min(1)
      }),
    output_schema:
      Zoi.object(%{
        chunks: Zoi.list(Zoi.map()),
        count: Zoi.integer(),
        unavailable_ids: Zoi.list(Zoi.integer())
      })

  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(%{chunk_ids: ids}, context) do
    access_opts =
      [
        person_id: context[:person_id],
        team_ids: Map.get(context, :team_ids, []),
        skip_permissions: Map.get(context, :skip_permissions, false),
        source_filter: context[:source_filter]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    event =
      Event.new(%{chunk_ids: ids, access_opts: access_opts}, :ingestion,
        actor: context[:execution_actor],
        opts: [action: :get_knowledge_base_chunks]
      )

    router = Map.get(context, :node_router, NodeRouter)
    router.dispatch(event).response
  end
end
