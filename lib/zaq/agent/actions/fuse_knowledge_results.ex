defmodule Zaq.Agent.Actions.FuseKnowledgeResults do
  @moduledoc """
  Composes ordered keyword and semantic result lists using Ingestion's RRF.

  Inputs are already ranked retrieval outputs. Using their ordinal positions
  preserves ranks even when ACL redaction removed a match's measured scores.
  Fusion fetches no content, elevates no permission and performs no model calls.
  """

  use Zaq.Engine.Workflows.Action,
    name: "fuse_knowledge_results",
    description: "Fuse ranked keyword and semantic chunks with configured weighted RRF",
    schema:
      Zoi.object(%{keyword_chunks: Zoi.list(Zoi.map()), semantic_chunks: Zoi.list(Zoi.map())}),
    output_schema: Zoi.object(%{chunks: Zoi.list(Zoi.map())})

  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(params, context) do
    router = Map.get(context, :node_router, NodeRouter)

    event =
      Event.new(params, :ingestion,
        actor: context[:execution_actor],
        opts: [action: :fuse_knowledge_results]
      )

    router.dispatch(event).response
  end
end
