defmodule Zaq.Agent.Tools.DataSource.CreateDocument do
  @moduledoc """
  ReAct tool: creates a document on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  @output_schema Zoi.object(
                   %{
                     record:
                       Zaq.Contracts.Record.zoi_type(
                         description: "Created document metadata record"
                       )
                       |> Zoi.optional()
                   },
                   unrecognized_keys: :preserve
                 )

  use Zaq.Engine.Workflows.Action,
    name: "create_document",
    output_schema: @output_schema,
    description: """
    Create a document on a specific datasource provider.
    Returns provider metadata for the created document.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      name: [type: :string, required: true, doc: "Document name/title"],
      content: [type: :string, required: false, doc: "Optional textual content to create"],
      path: [type: :string, required: false, doc: "Optional provider parent folder path"],
      parent_id: [type: :string, required: false, doc: "Optional provider parent identifier"],
      mime_type: [type: :string, required: false, doc: "Optional provider MIME type"],
      kind: [type: :string, required: false, doc: "Optional canonical item kind, e.g. folder"],
      encoding: [type: :string, required: false, doc: "Optional content encoding, e.g. base64"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Agent.Tools.General.DecodeBase64

  @impl Jido.Action
  def run(%{provider: provider} = params, context) do
    with {:ok, params} <- maybe_decode_content(params) do
      request =
        %{}
        |> DataSourceTool.merge_optional(params, [
          :name,
          :content,
          :path,
          :parent_id,
          :mime_type,
          :kind,
          :encoding,
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

  defp maybe_decode_content(%{encoding: "base64", content: content} = params)
       when is_binary(content) do
    case DecodeBase64.run(%{data: content, variant: "standard"}, %{}) do
      {:ok, %{decoded: decoded}} -> {:ok, %{params | content: decoded, encoding: nil}}
      {:error, reason} -> {:error, "Invalid base64 content: #{reason}"}
    end
  end

  defp maybe_decode_content(params), do: {:ok, params}
end
