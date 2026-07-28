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
    The provider is never assumed: when the user has not said where the document
    should go, call list_channel_providers with kind "data_source" and ask them
    to choose first.
    With provider "disk" the document lands on the local ZAQ volume — reference
    the returned path with @path so the user can preview it.
    Returns provider metadata for the created document.
    """,
    schema: [
      provider: [
        type: :string,
        required: true,
        doc:
          ~s|Datasource provider key (e.g. "disk", "google_drive", "sharepoint") — | <>
            ~s|get the valid keys from list_channel_providers with kind "data_source"|
      ],
      name: [type: :string, required: true, doc: "Document name/title"],
      content: [type: :string, required: false, doc: "Optional textual content to create"],
      path: [type: :string, required: false, doc: "Optional provider path/parent folder"],
      parent_id: [type: :string, required: false, doc: "Optional provider parent identifier"],
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
