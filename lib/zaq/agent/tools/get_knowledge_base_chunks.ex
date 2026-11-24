defmodule Zaq.Agent.Tools.GetKnowledgeBaseChunks do
  @moduledoc """
  Retrieves one or multiple exact knowledge chunks through the Ingestion role.

  Trusted execution context supplies access restrictions. A chunk ID never grants
  access: Ingestion rechecks current document permissions for every request.
  """

  use Zaq.Engine.Workflows.Action,
    name: "get_knowledge_base_chunks",
    description: """
    Fetch one or multiple knowledge chunks by ID only when their content is needed.
    Search results already contain usable content. Do not fetch content already visible
    unless you need to refresh it or recover content pruned from your context.
    Follow returned neighbor IDs (previous_chunk_id/next_chunk_id) from search or fetch
    results to read missing context. Never guess IDs or assume a contiguous ID range.
    Returns only the requested accessible chunks, in requested order; missing or
    inaccessible IDs are unavailable. Does not search or expand neighbors.
    Current document permissions are rechecked on every fetch; knowing an ID grants no access.
    Stop retrieving once you have sufficient evidence to answer.
    Cite sources used in your answer as [[source:path]], using paths from sources.
    """,
    schema:
      Zoi.object(%{
        chunk_ids: Zoi.list(Zoi.integer() |> Zoi.positive()) |> Zoi.min(1)
      }),
    output_schema:
      Zoi.object(%{
        chunks: Zoi.list(Zoi.map()),
        sources: Zoi.list(Zoi.string()),
        count: Zoi.integer(),
        unavailable_ids: Zoi.list(Zoi.integer())
      })

  alias Zaq.Agent.KnowledgeAccess
  alias Zaq.Agent.Tools.KnowledgeSources
  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(%{chunk_ids: ids}, context) do
    event =
      Event.new(%{chunk_ids: ids, access_opts: KnowledgeAccess.options(context)}, :ingestion,
        actor: context[:actor],
        opts: [action: :get_knowledge_base_chunks]
      )

    router = Map.get(context, :node_router, NodeRouter)

    with {:ok, %{chunks: chunks} = result} <- router.dispatch(event).response do
      {:ok, Map.put(result, :sources, KnowledgeSources.from_chunks(chunks))}
    end
  end
end
