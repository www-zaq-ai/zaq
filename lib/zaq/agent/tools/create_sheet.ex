defmodule Zaq.Agent.Tools.CreateSheet do
  @moduledoc """
  ReAct tool: creates a spreadsheet on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.

  ## Example

      iex> Zaq.Agent.Tools.CreateSheet.run(
      ...>   %{provider: "google_drive", title: "Roadmap"},
      ...>   %{}
      ...> )
      {:ok, %{status: "created", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Jido.Action,
    name: "create_sheet",
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
