defmodule Zaq.Agent.Tools.GoogleSheets.ExtractRows do
  @moduledoc """
  Workflow action: converts raw Google Sheet content into normalized row maps.

  Accepts a `record` from `GetSheet` and returns a list of maps where:
  - Keys are downcased column headers
  - Boolean strings ("TRUE"/"FALSE") are cast to booleans
  - Numeric strings are cast to integers
  - Each row includes a `"row_index"` (1-based, headers = row 1)

  ## Example

      iex> Zaq.Agent.Tools.GoogleSheets.ExtractRows.run(
      ...>   %{record: %{content: [["Name", "Active"], ["Alice", "TRUE"]]}},
      ...>   %{}
      ...> )
      {:ok, %{rows: [%{"name" => "Alice", "active" => true, "row_index" => 2}]}}
  """

  use Jido.Action,
    name: "extract_sheet_rows",
    description: "Convert raw sheet content into a normalized list of row maps.",
    schema: [record: [type: :any, required: true, doc: "Spreadsheet record from GetSheet"]],
    output_schema: [rows: [type: {:list, :any}, required: true, doc: "Normalized row maps"]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{record: record}, _ctx) do
    content = Map.get(record, :content) || Map.get(record, "content")

    rows =
      case content do
        [headers | data_rows] when is_list(headers) ->
          normalized_headers = Enum.map(headers, &String.downcase/1)

          data_rows
          |> Enum.with_index(2)
          |> Enum.map(fn {row, row_index} -> build_row(normalized_headers, row, row_index) end)

        [_ | rest] ->
          rest
          |> Enum.with_index(2)
          |> Enum.map(fn {row, row_index} -> build_map_row(row, row_index) end)

        _ ->
          []
      end

    {:ok, %{rows: rows}}
  end

  defp build_row(headers, row, row_index) do
    headers
    |> Enum.zip(row)
    |> Map.new(fn {k, v} -> {k, normalize_value(v)} end)
    |> Map.put("row_index", row_index)
  end

  defp build_map_row(row, row_index) do
    row
    |> stringify_keys()
    |> Map.new(fn {k, v} -> {k, normalize_value(v)} end)
    |> Map.put("row_index", row_index)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k |> to_string() |> String.downcase(), v} end)

  defp stringify_keys(v), do: v

  defp normalize_value("TRUE"), do: true
  defp normalize_value("FALSE"), do: false
  defp normalize_value("true"), do: true
  defp normalize_value("false"), do: false

  defp normalize_value(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> v
    end
  end

  defp normalize_value(v), do: v
end
