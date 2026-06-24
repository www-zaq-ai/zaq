defmodule Zaq.Agent.Tools.DataSource.CreateDocument do
  @moduledoc """
  ReAct tool: creates a document on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Zaq.Engine.Workflows.Action,
    name: "create_document",
    output_schema: [
      record: [type: :any, required: false, doc: "Created document metadata record"]
    ],
    description: """
    Create a document on a specific datasource provider.
    Returns provider metadata for the created document.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      name: [type: :string, required: true, doc: "Document name/title"],
      content: [type: :string, required: false, doc: "Optional textual content to create"],
      path: [type: :string, required: false, doc: "Optional provider path/parent folder"],
      parent_id: [type: :string, required: false, doc: "Optional provider parent identifier"],
      parents: [
        type: {:list, :string},
        required: false,
        doc: "Optional provider parent identifiers"
      ],
      mime_type: [type: :string, required: false, doc: "Optional provider MIME type"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  @impl Jido.Action
  def run(%{provider: provider} = params, context) do
    request =
      %{}
      |> DataSourceTool.merge_optional(params, [
        :name,
        :content,
        :path,
        :parent_id,
        :parents,
        :mime_type,
        :config_id
      ])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_create_file,
      request,
      context,
      "Data source document creation failed"
    )
  end
end
