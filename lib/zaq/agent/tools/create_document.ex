defmodule Zaq.Agent.Tools.CreateDocument do
  @moduledoc """
  ReAct tool: creates a document on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Jido.Action,
    name: "create_document",
    description: """
    Create a document on a specific datasource provider.
    Returns provider metadata for the created document.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      name: [type: :string, required: true, doc: "Document name/title"],
      content: [type: :string, required: true, doc: "Textual content to create"],
      path: [type: :string, required: false, doc: "Optional provider path/parent folder"],
      parent_id: [type: :string, required: false, doc: "Optional provider parent identifier"],
      mime_type: [type: :string, required: false, doc: "Optional provider MIME type"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  def run(%{provider: provider} = params, context) do
    request =
      %{}
      |> DataSourceTool.put_if_present("name", Map.get(params, :name))
      |> DataSourceTool.put_if_present("content", Map.get(params, :content))
      |> DataSourceTool.put_if_present("path", Map.get(params, :path))
      |> DataSourceTool.put_if_present("parent_id", Map.get(params, :parent_id))
      |> DataSourceTool.put_if_present("mime_type", Map.get(params, :mime_type))
      |> DataSourceTool.put_if_present("config_id", Map.get(params, :config_id))
      |> then(&%{provider: provider, params: &1})

    DataSourceTool.dispatch(
      :data_source_create_file,
      request,
      context,
      "Data source document creation failed"
    )
  end
end
