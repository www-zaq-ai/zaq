defmodule Zaq.Agent.Tools.DataSource.CreateDocument do
  @moduledoc """
  ReAct tool: creates a document on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  @schema Zoi.object(%{
            provider: Zoi.string(description: "Datasource provider key"),
            name: Zoi.string(description: "Document name/title"),
            content:
              Zoi.string(description: "Optional textual content to create")
              |> Zoi.optional(),
            encoding:
              Zoi.string(description: "Optional content encoding, e.g. base64 for binary content")
              |> Zoi.optional(),
            path:
              Zoi.string(description: "Optional provider path/parent folder")
              |> Zoi.optional(),
            parent_id:
              Zoi.string(description: "Optional provider parent identifier")
              |> Zoi.optional(),
            mime_type:
              Zoi.string(description: "Optional provider MIME type")
              |> Zoi.optional(),
            config_id:
              Zoi.string(description: "Optional scoped datasource config id")
              |> Zoi.optional()
          })

  @output_schema Zoi.object(%{
                   record:
                     Zoi.any(description: "Created document metadata record")
                     |> Zoi.optional()
                 })

  use Zaq.Engine.Workflows.Action,
    name: "create_document",
    description: """
    Create a document on a specific datasource provider.
    Returns provider metadata for the created document.
    """,
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Agent.Tools.Helpers.ChannelTool

  @impl Jido.Action
  def run(%{provider: provider} = params, context) do
    request =
      %{}
      |> ChannelTool.merge_optional(params, [
        :name,
        :content,
        :encoding,
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
