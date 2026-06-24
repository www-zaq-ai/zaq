defmodule Zaq.Agent.Tools.Sheets.UpdateSheetValues do
  @moduledoc """
  ReAct tool: updates spreadsheet values on a datasource provider.

  Two input modes are supported:

  - **Range mode** — pass an explicit A1 `range` and a 2D `values` matrix.
  - **Single-cell mode** — pass `row` + `column` (and an optional `sheet_name`,
    default `"Sheet1"`) and a scalar `value`. The tool builds the A1 range
    (`"Sheet1!I5"`) and wraps the value (`[[value]]`) for you. The value is
    written verbatim — pre-compute it upstream (e.g. a `Workflow.Increment`
    node) if it needs transforming.

  Range mode wins when a `range` is present.

  ## Example

      # range mode
      iex> Zaq.Agent.Tools.Sheets.UpdateSheetValues.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", range: "Sheet1!A1:B1", values: [["ok", 1]]},
      ...>   %{}
      ...> )
      {:ok, %{status: "updated", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}

      # single-cell mode → range "Sheet1!I5", values [[3]]
      iex> Zaq.Agent.Tools.Sheets.UpdateSheetValues.run(
      ...>   %{provider: "google_drive", spreadsheet_id: "sheet-123", row: 5, column: "I", value: 3},
      ...>   %{}
      ...> )
      {:ok, %{status: "updated", record: %Zaq.Contracts.Record{kind: :spreadsheet}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "update_sheet_values",
    description: """
    Update values in a spreadsheet on a specific datasource provider, either by
    explicit range + values matrix, or by row + column + a single value.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      spreadsheet_id: [type: :string, required: true, doc: "Spreadsheet identifier"],
      range: [
        type: :string,
        required: false,
        doc:
          "A1 range to update (range mode). Values dimensions must fit this range (for example 2 columns in range means max 2 values per row)."
      ],
      values: [
        type: {:list, {:list, :any}},
        required: false,
        doc:
          "2D matrix of values (range mode). Row/column counts must fit the target range width/height."
      ],
      row: [type: :any, required: false, doc: "Row number for single-cell mode (1-based)."],
      column: [
        type: :string,
        required: false,
        doc: "Column letter for single-cell mode (for example \"I\")."
      ],
      sheet_name: [
        type: :string,
        required: false,
        doc: "Sheet/tab name for single-cell mode (default \"Sheet1\")."
      ],
      value: [
        type: :any,
        required: false,
        doc: "Scalar value for single-cell mode; written as-is inside [[value]]."
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
      record: [
        type: {:struct, Zaq.Contracts.Record},
        required: false,
        doc: "Datasource record returned by the provider."
      ]
    ]

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Contracts.Record

  @spec run(
          %{
            required(:provider) => String.t(),
            required(:spreadsheet_id) => String.t(),
            optional(:range) => String.t(),
            optional(:values) => [[term()]],
            optional(:row) => term(),
            optional(:column) => String.t(),
            optional(:sheet_name) => String.t(),
            optional(:value) => term(),
            optional(:value_input_option) => String.t(),
            optional(:config_id) => String.t()
          },
          map()
        ) :: {:ok, map()} | {:error, String.t()}
  @impl Jido.Action
  def run(%{provider: provider} = params, context) do
    with {:ok, range} <- resolve_range(params),
         {:ok, values} <- resolve_values(params) do
      request =
        %{
          "spreadsheet_id" => Map.fetch!(params, :spreadsheet_id),
          "range" => range,
          "values" => values
        }
        |> DataSourceTool.merge_optional(params, [:value_input_option, :config_id])
        |> DataSourceTool.wrap_request(provider)

      DataSourceTool.dispatch(
        :data_source_sheet_update_values,
        request,
        context,
        "Data source sheet update failed",
        &validate_sheet_response/1
      )
    end
  end

  # Range mode wins when an explicit range is present; otherwise build the A1
  # range from row + column (+ optional sheet_name).
  defp resolve_range(params) do
    case fetch(params, :range) do
      {:ok, range} when is_binary(range) ->
        {:ok, range}

      _ ->
        with {:ok, row} <- fetch(params, :row),
             {:ok, column} <- fetch(params, :column) do
          {:ok, "#{sheet_name(params)}!#{column}#{row}"}
        else
          :missing ->
            {:error, "Data source sheet update failed: provide a range, or row and column"}
        end
    end
  end

  defp resolve_values(params) do
    case fetch(params, :values) do
      {:ok, values} when not is_nil(values) ->
        {:ok, values}

      _ ->
        case fetch(params, :value) do
          {:ok, value} -> {:ok, [[value]]}
          :missing -> {:error, "Data source sheet update failed: provide values, or a value"}
        end
    end
  end

  defp sheet_name(params) do
    case fetch(params, :sheet_name) do
      {:ok, name} when is_binary(name) -> name
      _ -> "Sheet1"
    end
  end

  # Reads a param by atom key, falling back to the string key (workflow mappings
  # may carry either). Returns `:missing` when the key is absent.
  defp fetch(params, key) do
    cond do
      Map.has_key?(params, key) -> {:ok, Map.get(params, key)}
      Map.has_key?(params, Atom.to_string(key)) -> {:ok, Map.get(params, Atom.to_string(key))}
      true -> :missing
    end
  end

  defp validate_sheet_response(%{record: %Record{}} = payload), do: {:ok, payload}

  defp validate_sheet_response(%{} = payload) when not is_map_key(payload, :record),
    do: {:ok, payload}

  defp validate_sheet_response(_payload) do
    {:error, "Data source sheet update failed: expected record to be %Zaq.Contracts.Record{}"}
  end
end
