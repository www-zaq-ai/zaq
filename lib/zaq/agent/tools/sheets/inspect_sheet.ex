defmodule Zaq.Agent.Tools.Sheets.InspectSheet do
  @moduledoc """
  ReAct tool: inspects spreadsheet metadata from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.

  ## Example

      iex> Zaq.Agent.Tools.Sheets.InspectSheet.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123"},
      ...>   %{}
      ...> )
      {:ok, %{record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "inspect_sheet",
    output_schema: [
      record: [type: :any, required: false, doc: "Normalized spreadsheet metadata record"]
    ],
    description: """
    Inspect spreadsheet metadata from a specific datasource provider.
    Returns normalized spreadsheet metadata and tabs.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  @impl Jido.Action

  def run(%{provider: provider, spreadsheet_id: spreadsheet_id} = params, context) do
    request =
      %{"spreadsheet_id" => spreadsheet_id}
      |> DataSourceTool.merge_optional(params, [:config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_sheet_inspect,
      request,
      context,
      "Data source sheet inspect failed"
    )
  end
end
