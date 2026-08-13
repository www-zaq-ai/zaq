defmodule Zaq.Agent.Tools.DataSource.DownloadDocument do
  @moduledoc """
  ReAct tool: downloads a document by id from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`. A bridge that answers with an
  unmaterialized record — `content: nil` plus a `materializing_event` — takes a second hop
  through that event, so the tool returns content whichever way the provider works.
  """

  @schema Zoi.object(%{
            provider: Zoi.string(description: "Datasource provider key"),
            document_id: Zoi.string(description: "Provider document identifier"),
            document_mime_type:
              Zoi.string(
                description:
                  "Optional source MIME type of the provider document. Used for automatic export type decision."
              )
              |> Zoi.optional(),
            export_mime_type:
              Zoi.string(
                description: "Optional target MIME type to request provider export when supported"
              )
              |> Zoi.optional(),
            config_id:
              Zoi.string(description: "Optional scoped datasource config id")
              |> Zoi.optional()
          })

  @output_schema Zoi.object(%{
                   record:
                     Zoi.any(description: "Normalized record including document content")
                     |> Zoi.optional()
                 })

  use Zaq.Engine.Workflows.Action,
    name: "download_document",
    description: """
    Download a document by id from a specific datasource provider.
    Returns a normalized record including document content.
    """,
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Agent.Tools.Helpers.ChannelTool

  @error_prefix "Data source document download failed"

  @impl Jido.Action

  def run(%{provider: provider, document_id: document_id} = params, context) do
    request =
      %{"file_id" => document_id}
      |> ChannelTool.merge_optional(params, [
        :document_mime_type,
        :export_mime_type,
        :config_id
      ])
      |> ChannelTool.wrap_request(provider)

    ChannelTool.dispatch(
      :data_source_download_document,
      request,
      context,
      @error_prefix,
      &ChannelTool.materialize(&1, context, @error_prefix)
    )
  end
end
