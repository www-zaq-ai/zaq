defmodule Zaq.Agent.Tools.Sheets.CreateSheet do
  @moduledoc """
  ReAct tool: creates a spreadsheet on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.

  ## Example

      iex> Zaq.Agent.Tools.Sheets.CreateSheet.run(
      ...>   %{provider: "google_drive", title: "Roadmap"},
      ...>   %{}
      ...> )
      {:ok, %{status: "created", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "create_sheet",
    output_schema: [
      status: [type: :string, required: false, doc: "Operation status"],
      record: [type: :any, required: false, doc: "Created spreadsheet record"]
    ],
    description: """
    Create a spreadsheet on a specific datasource provider.
    Returns normalized spreadsheet metadata.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      title: [type: :string, required: true, doc: "Spreadsheet title"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  @impl Jido.Action

  def run(%{provider: provider, title: title} = params, context) do
    request =
      %{"title" => title}
      |> DataSourceTool.merge_optional(params, [:config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_sheet_create,
      request,
      context,
      "Data source sheet creation failed"
    )
  end
end
