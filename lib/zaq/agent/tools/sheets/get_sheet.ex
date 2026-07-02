defmodule Zaq.Agent.Tools.Sheets.GetSheet do
  @moduledoc """
  ReAct tool: gets spreadsheet data from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.

  ## Example

      iex> Zaq.Agent.Tools.Sheets.GetSheet.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", range: "Sheet1!A1:C5"},
      ...>   %{}
      ...> )
      {:ok, %{record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "get_sheet",
    description: """
    Read spreadsheet data from a specific datasource provider.
    Returns normalized spreadsheet/range data.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      range: [type: :string, required: false, doc: "Optional A1 range"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ],
    output_schema: [
      record: [
        type: {:struct, Zaq.Contracts.Record},
        required: true,
        doc: "Normalized spreadsheet record."
      ]
    ]

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Contracts.Record

  @spec run(
          %{
            required(:provider) => String.t(),
            required(:spreadsheet_id) => String.t(),
            optional(:range) => String.t(),
            optional(:config_id) => String.t()
          },
          map()
        ) :: {:ok, %{record: Record.t()}} | {:error, String.t()}
  @impl Jido.Action
  def run(%{provider: provider, spreadsheet_id: spreadsheet_id} = params, context) do
    request =
      %{"spreadsheet_id" => spreadsheet_id}
      |> DataSourceTool.merge_optional(params, [:range, :config_id])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_sheet_get,
      request,
      context,
      "Data source sheet read failed",
      &validate_sheet_response/1
    )
  end

  defp validate_sheet_response(%{record: %Record{}} = payload), do: {:ok, payload}

  defp validate_sheet_response(_payload) do
    {:error, "Data source sheet read failed: expected record to be %Zaq.Contracts.Record{}"}
  end
end
