defmodule Zaq.Agent.Tools.AppendSheetValues do
  @moduledoc """
  ReAct tool: appends spreadsheet rows on a datasource provider.

  ## Example

      iex> Zaq.Agent.Tools.AppendSheetValues.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", range: "Sheet1!A:C", values: [["a", "b", "c"]]},
      ...>   %{}
      ...> )
      {:ok, %{status: "appended", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Jido.Action,
    name: "append_sheet_values",
    description: """
    Append rows to the end of a spreadsheet range on a specific datasource provider.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      range: [
        type: :string,
        required: true,
        doc: "A1 range anchor for append, provider chooses insertion row"
      ],
      values: [type: {:list, {:list, :any}}, required: true, doc: "2D matrix of values"],
      value_input_option: [
        type: :string,
        required: false,
        doc: "Provider value input option (for example USER_ENTERED)"
      ],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

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
      :data_source_sheet_append_values,
      request,
      context,
      "Data source sheet append failed"
    )
  end
end
