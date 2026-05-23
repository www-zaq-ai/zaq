defmodule Zaq.Agent.Tools.ClearSheetValues do
  @moduledoc """
  ReAct tool: clears spreadsheet range values on a datasource provider.

  ## Example

      iex> Zaq.Agent.Tools.ClearSheetValues.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", range: "Sheet1!A1:C10"},
      ...>   %{}
      ...> )
      {:ok, %{status: "cleared", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Jido.Action,
    name: "clear_sheet_values",
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
