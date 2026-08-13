defmodule Zaq.Agent.Tools.DataSource.ListDocuments do
  @moduledoc """
  ReAct tool: lists documents for a path from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Zaq.Engine.Workflows.Action,
    name: "list_documents",
    output_schema: [
      records: [type: {:list, :any}, required: false, doc: "Document metadata records"],
      count: [type: :integer, required: false, doc: "Number of records returned"]
    ],
    description: """
    List documents from a specific datasource provider path.
    Returns metadata records only.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      path: [type: :string, required: true, doc: "Provider path to list"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.Helpers.ChannelTool

  @impl Jido.Action

  def run(%{provider: provider, path: path} = params, context) do
    request =
      %{"path" => path}
      |> ChannelTool.merge_optional(params, [:config_id])
      |> ChannelTool.wrap_request(provider)

    ChannelTool.dispatch(
      :data_source_list_files,
      request,
      context,
      "Data source document listing failed",
      &on_ok/1
    )
  end

  defp on_ok(%{records: records} = payload) when is_list(records) do
    {:ok, Map.put_new(payload, :count, length(records))}
  end

  defp on_ok(payload), do: {:ok, payload}
end
