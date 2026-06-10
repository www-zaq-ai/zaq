defmodule Zaq.Agent.Tools.GoogleSheets.UpdateSheetValues do
  @moduledoc """
  ReAct tool: updates spreadsheet range values on a datasource provider.

  ## Example

      iex> Zaq.Agent.Tools.GoogleSheets.UpdateSheetValues.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", range: "Sheet1!A1:B1", values: [["ok", 1]]},
      ...>   %{}
      ...> )
      {:ok, %{status: "updated", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Jido.Action,
    name: "update_sheet_values",
    description: """
    Update values in a spreadsheet range on a specific datasource provider.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      range: [
        type: :string,
        required: true,
        doc:
          "A1 range to update. Values dimensions must fit this range (for example 2 columns in range means max 2 values per row)."
      ],
      values: [
        type: {:list, {:list, :any}},
        required: true,
        doc: "2D matrix of values. Row/column counts must fit the target range width/height."
      ],
      value_input_option: [
        type: :string,
        required: false,
        doc: "Provider value input option (for example USER_ENTERED)"
      ],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ],
    output_schema: [
      status: [type: :string, required: true, doc: "Result status, e.g. \"updated\"."],
      record: [type: :any, required: false, doc: "Datasource record returned by the provider."]
    ]

  use Zaq.Engine.Workflows.Action

  alias Zaq.Agent.Tools.DataSourceTool

  @impl Jido.Action
  def run(%{provider: provider} = params, context) do
    request =
      %{
        "spreadsheet_id" => Map.fetch!(params, :spreadsheet_id),
        "range" => Map.fetch!(params, :range),
        "values" => Map.fetch!(params, :values)
      }
      |> DataSourceTool.merge_optional(params, [:value_input_option, :config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_sheet_update_values,
      request,
      context,
      "Data source sheet update failed"
    )
  end
end
