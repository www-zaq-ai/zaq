defmodule Zaq.Agent.Tools.DeleteSheetTab do
  @moduledoc """
  ReAct tool: deletes a tab from a spreadsheet on a datasource provider.

  ## Example

      iex> Zaq.Agent.Tools.DeleteSheetTab.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", sheet_id: "0"},
      ...>   %{}
      ...> )
      {:ok, %{status: "deleted", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Jido.Action,
    name: "delete_sheet_tab",
    description: """
    Delete a tab in a spreadsheet on a specific datasource provider.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      sheet_id: [type: :string, required: true, doc: "Sheet tab identifier"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  def run(
        %{provider: provider, spreadsheet_id: spreadsheet_id, sheet_id: sheet_id} = params,
        context
      ) do
    request =
      %{"spreadsheet_id" => spreadsheet_id, "sheet_id" => sheet_id}
      |> DataSourceTool.merge_optional(params, [:config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_sheet_delete_tab,
      request,
      context,
      "Data source sheet tab deletion failed"
    )
  end
end
