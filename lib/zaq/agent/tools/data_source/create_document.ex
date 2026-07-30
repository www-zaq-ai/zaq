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
    Returns provider metadata for the created document.
    """,
    schema: [
      provider: [
        type: :string,
        required: true,
        doc:
          ~s|Datasource provider key (e.g. "google_drive", "sharepoint") — get | <>
            ~s|the valid keys from list_channel_providers with kind "data_source"|
      ],
      name: [type: :string, required: true, doc: "Document name/title"],
      content: [type: :string, required: false, doc: "Optional textual content to create"],
      path: [type: :string, required: false, doc: "Optional provider path/parent folder"],
      parent_id: [type: :string, required: false, doc: "Optional provider parent identifier"],
      mime_type: [type: :string, required: false, doc: "Optional provider MIME type"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.ChannelTool

  @impl Jido.Action
  def run(%{provider: provider} = params, context) do
    request =
      %{}
      |> ChannelTool.merge_optional(params, [
        :name,
        :content,
        :path,
        :parent_id,
        :mime_type,
        :config_id
      ])
      |> ChannelTool.wrap_request(provider)

    ChannelTool.dispatch(
      :data_source_create_file,
      request,
      context,
      "Data source document creation failed"
    )
  end
end
