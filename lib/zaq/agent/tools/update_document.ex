defmodule Zaq.Agent.Tools.UpdateDocument do
  @moduledoc """
  ReAct tool: updates a document on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Jido.Action,
    name: "update_document",
    description: """
    Update a document by id on a specific datasource provider.
    Returns provider metadata for the updated document.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      document_id: [type: :string, required: true, doc: "Provider document identifier"],
      name: [type: :string, required: false, doc: "Optional updated document name/title"],
      content: [type: :string, required: false, doc: "Optional updated textual content"],
      path: [type: :string, required: false, doc: "Optional updated provider path/parent folder"],
      parent_id: [
        type: :string,
        required: false,
        doc: "Optional updated provider parent identifier"
      ],
      mime_type: [type: :string, required: false, doc: "Optional updated provider MIME type"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  def run(%{provider: provider, document_id: document_id} = params, context) do
    request =
      %{"file_id" => document_id}
      |> DataSourceTool.put_if_present("name", Map.get(params, :name))
      |> DataSourceTool.put_if_present("content", Map.get(params, :content))
      |> DataSourceTool.put_if_present("path", Map.get(params, :path))
      |> DataSourceTool.put_if_present("parent_id", Map.get(params, :parent_id))
      |> DataSourceTool.put_if_present("mime_type", Map.get(params, :mime_type))
      |> DataSourceTool.put_if_present("config_id", Map.get(params, :config_id))
      |> then(&%{provider: provider, params: &1})

    DataSourceTool.dispatch(
      :data_source_update_file,
      request,
      context,
      "Data source document update failed"
    )
  end
end
