defmodule Zaq.Agent.Tools.DataSource.GetDocument do
  @moduledoc """
  ReAct tool: gets a document by id from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Zaq.Engine.Workflows.Action,
    name: "get_document",
    output_schema: [
      record: [type: :any, required: false, doc: "Selected document metadata record"]
    ],
    description: """
    Get a document by id from a specific datasource provider.
    Returns metadata for the selected document.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      document_id: [type: :string, required: true, doc: "Provider document identifier"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  @impl Jido.Action

  def run(%{provider: provider, document_id: document_id} = params, context) do
    request =
      %{"file_id" => document_id}
      |> DataSourceTool.merge_optional(params, [:config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_get_file,
      request,
      context,
      "Data source document request failed"
    )
  end
end
