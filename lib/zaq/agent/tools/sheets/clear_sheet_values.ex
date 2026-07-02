defmodule Zaq.Agent.Tools.Sheets.ClearSheetValues do
  @moduledoc """
  ReAct tool: clears spreadsheet range values on a datasource provider.

  ## Example

      iex> Zaq.Agent.Tools.Sheets.ClearSheetValues.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", range: "Sheet1!A1:C10"},
      ...>   %{}
      ...> )
      {:ok, %{status: "cleared", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "clear_sheet_values",
    output_schema: [
      status: [type: :string, required: false, doc: "Operation status"],
      record: [type: :any, required: false, doc: "Updated spreadsheet record"]
    ],
    description: """
    Clear values in a spreadsheet range on a specific datasource provider.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      range: [type: :string, required: true, doc: "A1 range to clear"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  @impl Jido.Action

  def run(%{provider: provider, spreadsheet_id: spreadsheet_id, range: range} = params, context) do
    request =
      %{"spreadsheet_id" => spreadsheet_id, "range" => range}
      |> DataSourceTool.merge_optional(params, [:config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_sheet_clear_values,
      request,
      context,
      "Data source sheet clear failed"
    )
  end
end
