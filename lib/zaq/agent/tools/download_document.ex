defmodule Zaq.Agent.Tools.DownloadDocument do
  @moduledoc """
  ReAct tool: downloads a document by id from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Jido.Action,
    name: "download_document",
    description: """
    Download a document by id from a specific datasource provider.
    Returns a normalized record including document content.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      document_id: [type: :string, required: true, doc: "Provider document identifier"],
      document_mime_type: [
        type: :string,
        required: false,
        doc:
          "Optional source MIME type of the provider document. Used for automatic export type decision."
      ],
      export_mime_type: [
        type: :string,
        required: false,
        doc: "Optional target MIME type to request provider export when supported"
      ],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  def run(%{provider: provider, document_id: document_id} = params, context) do
    request =
      %{"file_id" => document_id}
      |> DataSourceTool.put_if_present("document_mime_type", Map.get(params, :document_mime_type))
      |> DataSourceTool.put_if_present("export_mime_type", Map.get(params, :export_mime_type))
      |> DataSourceTool.put_if_present("config_id", Map.get(params, :config_id))
      |> then(&%{provider: provider, params: &1})

    DataSourceTool.dispatch(
      :data_source_download_document,
      request,
      context,
      "Data source document download failed"
    )
  end
end
