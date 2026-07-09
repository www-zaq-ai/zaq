defmodule Zaq.Engine.Workflows.Node do
  @moduledoc """
  Behaviour for workflow node types that need build-time enrichment and/or
  save-time validation.

  Generic graph wiring (adding nodes/edges, condition guards, assembly) stays in
  `Zaq.Engine.Workflows.DagBuilder`. Anything that depends on a node *type* —
  resolving an orchestrator's inline sub-pipelines, injecting type-specific
  params, type-specific validation — lives behind these callbacks in the node's
  own module, so adding a new orchestrator node means editing that module rather
  than the builder.

  ## `enrich/2`

  Called by `DagBuilder` once per top-level node (and recursively for inline
  sub-pipeline nodes) before the DAG is assembled. Receives the raw node map and
  the full list of sibling node maps, and returns the node map augmented with any
  type-specific fields (e.g. resolved `:process` / `:__batch_field__`). Modules
  without enrichment needs do not implement this callback — `DagBuilder` leaves
  their nodes untouched.

  ## `validate/1`

  Called at workflow save time so the persisted representation is always
  runnable. Returns `:ok` or `{:error, reason}` for a single node.

  Both callbacks are optional; a node module implements only what it needs.
  """

  @doc """
  Enriches a node map with type-specific fields before DAG assembly.

  `node` is the raw node map (string keys); `nodes_list` is the full list of
  sibling node maps. Returns `{:ok, enriched_node}` or `{:error, reason}`.
  """
  @callback enrich(node :: map(), nodes_list :: [map()]) :: {:ok, map()} | {:error, term()}

  @doc """
  Validates a single node map at save time. Returns `:ok` or `{:error, reason}`.
  """
  @callback validate(node :: map()) :: :ok | {:error, term()}

  @optional_callbacks enrich: 2, validate: 1
end
