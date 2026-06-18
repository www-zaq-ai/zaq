defmodule Zaq.Agent.Tools.Sheets.BuildSingleCellUpdate do
  @moduledoc """
  Builds the `range` and `values` payload for updating one spreadsheet cell.
  """

  use Zaq.Engine.Workflows.Action,
    name: "build_single_cell_update",
    description: "Build a single-cell spreadsheet update payload.",
    schema: [
      row_index: [type: :any, required: true, doc: "1-based sheet row number."],
      value: [type: :any, required: false, default: 0, doc: "Current value for the cell."],
      increment_by: [
        type: :integer,
        required: false,
        default: 0,
        doc: "Amount to add to the value before writing."
      ],
      column: [type: :string, required: false, default: "I", doc: "Target column letter."],
      sheet_name: [type: :string, required: false, default: "Sheet1", doc: "Target sheet tab."]
    ],
    output_schema: [
      range: [type: :string, required: true],
      values: [type: {:list, {:list, :any}}, required: true]
    ]

  @impl Jido.Action
  def run(%{row_index: row_index} = params, _context) do
    with {:ok, parsed_row} <- parse_positive_integer(row_index, "row_index"),
         {:ok, parsed_value} <- parse_integer(Map.get(params, :value, 0), "value") do
      column = Map.get(params, :column, "I")
      sheet_name = Map.get(params, :sheet_name, "Sheet1")
      increment_by = Map.get(params, :increment_by, 0)

      {:ok,
       %{
         range: "#{sheet_name}!#{column}#{parsed_row}",
         values: [[parsed_value + increment_by]]
       }}
    end
  end

  defp parse_positive_integer(value, field) do
    with {:ok, integer} <- parse_integer(value, field),
         true <- integer > 0 do
      {:ok, integer}
    else
      false -> {:error, "#{field}_must_be_positive"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_integer(value, _field) when is_integer(value), do: {:ok, value}

  defp parse_integer(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, "invalid_#{field}"}
    end
  end

  defp parse_integer(nil, _field), do: {:ok, 0}
  defp parse_integer(_value, field), do: {:error, "invalid_#{field}"}
end
