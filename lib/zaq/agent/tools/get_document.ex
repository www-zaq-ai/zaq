defmodule Zaq.Agent.Tools.GetDocument do
  @moduledoc """
  ReAct tool: gets a document by id from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Jido.Action,
    name: "get_document",
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

  def run(%{provider: provider, document_id: document_id} = params, context) do
    request =
      params
      |> build_params(%{"file_id" => document_id})
      |> then(&%{provider: provider, params: &1})

    DataSourceTool.dispatch(
      :data_source_get_file,
      request,
      context,
      "Data source document request failed"
    )
  end

  defp build_params(params, base) do
    case Map.get(params, :config_id) do
      nil -> base
      config_id -> Map.put(base, "config_id", config_id)
    end
  end
end
