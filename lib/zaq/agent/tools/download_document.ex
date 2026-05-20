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

  alias Zaq.Event
  alias Zaq.NodeRouter

  def run(%{provider: provider, document_id: document_id} = params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    request =
      %{"file_id" => document_id}
      |> maybe_put("document_mime_type", Map.get(params, :document_mime_type))
      |> maybe_put("export_mime_type", Map.get(params, :export_mime_type))
      |> maybe_put("config_id", Map.get(params, :config_id))
      |> then(&%{provider: provider, params: &1})

    event = Event.new(request, :channels, opts: [action: :data_source_download_document])

    case node_router.dispatch(event).response do
      {:ok, %{record: _} = payload} -> {:ok, payload}
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, "Data source document download failed: #{inspect(reason)}"}
      other -> {:error, "Unexpected data source response: #{inspect(other)}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
