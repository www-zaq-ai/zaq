defmodule Zaq.Agent.Tools.AddSheetTab do
  @moduledoc """
  ReAct tool: adds a tab to a spreadsheet on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.

  ## Examples

      iex> Zaq.Agent.Tools.AddSheetTab.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", title: "Q2"},
      ...>   %{}
      ...> )
      {:ok, %{status: "created", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}

      iex> Zaq.Agent.Tools.AddSheetTab.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", title: "Q2", auto_suffix_on_conflict: true},
      ...>   %{}
      ...> )
      {:ok, %{status: "created", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Jido.Action,
    name: "add_sheet_tab",
    description: """
    Add a new tab to a spreadsheet on a specific datasource provider.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      title: [type: :string, required: true, doc: "Tab title"],
      index: [type: :integer, required: false, doc: "Optional insertion index"],
      auto_suffix_on_conflict: [
        type: :boolean,
        required: false,
        doc: "When true, retry with a title suffix if the tab title already exists"
      ],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  def run(%{provider: provider, spreadsheet_id: spreadsheet_id, title: title} = params, context) do
    request =
      %{"spreadsheet_id" => spreadsheet_id, "title" => title}
      |> DataSourceTool.merge_optional(params, [:index, :auto_suffix_on_conflict, :config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_sheet_add_tab,
      request,
      context,
      "Data source add sheet tab failed"
    )
  end
end
