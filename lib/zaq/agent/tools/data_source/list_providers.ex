defmodule Zaq.Agent.Tools.DataSource.ListProviders do
  @moduledoc """
  ReAct tool: lists the datasource providers available for document operations.

  Exists so the agent can ask the user *where* a document should go instead of
  guessing a provider key — `Zaq.Agent.Tools.DataSource.CreateDocument` requires
  an explicit provider and never assumes one.

  Delegates to Channels through `NodeRouter.dispatch/1`.

  ## Expected context keys

  - `:node_router` — override the NodeRouter module (default `Zaq.NodeRouter`).
  """

  # NOTE: intentionally uses `Jido.Action` directly rather than
  # `Zaq.Engine.Workflows.Action`. This is a discovery tool with an empty input
  # schema (it takes no params), so it cannot satisfy the workflow action
  # contract's non-empty `schema`/`output_schema` requirement. A workflow step
  # knows its own provider at build time and has no use for the menu. See
  # `Zaq.Engine.Workflows.Action` for the contract.
  use Jido.Action,
    name: "list_data_source_providers",
    description: """
    List the datasource providers documents can be written to.

    USE THIS TOOL before creating a document when the user has not said where it
    should go — create_document requires an explicit provider and never picks
    one for you. Present the returned labels and let the user choose.

    Each entry has a `provider` key (pass this to create_document) and a
    human-readable `label` (show this to the user). "disk" is the local ZAQ
    volume and is always available, even with no connectors configured.
    """,
    schema: []

  alias Zaq.Agent.Tools.DataSourceTool

  def run(_params, context) do
    DataSourceTool.dispatch(
      :data_source_list_providers,
      %{},
      context,
      "Data source provider listing failed"
    )
  end
end
