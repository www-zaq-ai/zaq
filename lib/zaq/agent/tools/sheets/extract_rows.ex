defmodule Zaq.Agent.Tools.Sheets.ExtractRows do
  @moduledoc """
  Workflow action: normalizes the row content of a `%Zaq.Contracts.Record{}`
  into a list of plain row maps.

  Accepts a spreadsheet `record` (as produced by `GetSheet`) and reads its
  `content`, returning rows and extraction metadata where:
  - Keys are downcased column headers (taken from the header row), falling back
    to column letters for empty headers
  - Boolean strings ("TRUE"/"FALSE"/"true"/"false") are cast to booleans
  - Numeric strings are cast to integers
  - Each row includes a `"row_index"`
  - Metadata includes whether headers were detected and each extracted header's
    sheet column letter

  ## Header assumption

  By default (`header_row: true`) the **first** content row is treated as the
  column headers and data rows start at index 2 (1-based, headers = row 1).
  Set `header_row: false` when the content has no header row: list rows are then
  keyed by their sheet column letter (`"A"`, `"B"`, …) and `row_index` starts at 1,
  while map rows are kept as-is (the first row is not dropped).

  ## Input contract

  `record` must be a `%Zaq.Contracts.Record{}` struct. Any other value returns
  `{:error, {:invalid_input, :expected_record}}`.

  ## Example

      iex> Zaq.Agent.Tools.Sheets.ExtractRows.run(
      ...>   %{record: %Zaq.Contracts.Record{
      ...>     id: "sheet-1", kind: :spreadsheet,
      ...>     content: [["Name", "Active"], ["Alice", "TRUE"]]
      ...>   }},
      ...>   %{}
      ...> )
      {:ok, %{
        rows: [%{"name" => "Alice", "active" => true, "row_index" => 2}],
        metadata: %{
          headers_detected: true,
          headers: %{
            "name" => %{column: "A", original: "Name"},
            "active" => %{column: "B", original: "Active"}
          }
        }
      }}
  """

  use Zaq.Engine.Workflows.Action,
    name: "extract_sheet_rows",
    description: "Convert a record's sheet content into a normalized list of row maps.",
    schema: [
      record: [type: :any, required: true, doc: "Spreadsheet %Record{} from GetSheet"],
      header_row: [
        type: :boolean,
        default: true,
        doc: "Whether the first content row holds column headers."
      ]
    ],
    output_schema: [
      rows: [type: {:list, :any}, required: true, doc: "Normalized row maps"],
      metadata: [type: :map, required: true, doc: "Metadata about detected headers and columns"]
    ]

  alias Zaq.Contracts.Record

  @impl Jido.Action
  def run(%{record: %Record{content: content}} = params, _ctx) do
    header_row? = Map.get(params, :header_row, true)
    {rows, metadata} = extract(content, header_row?)
    {:ok, %{rows: rows, metadata: metadata}}
  end

  def run(%{record: _other}, _ctx) do
    {:error, {:invalid_input, :expected_record}}
  end

  # --- header_row: true (first row = headers) ---
  defp extract([headers | data_rows], true) when is_list(headers) do
    header_specs = build_header_specs(headers)
    header_keys = Enum.map(header_specs, fn {key, _metadata} -> key end)

    metadata = %{
      headers_detected: true,
      headers: Map.new(header_specs)
    }

    rows =
      data_rows
      |> Enum.with_index(2)
      |> Enum.map(fn {row, row_index} -> build_row(header_keys, row, row_index) end)

    {rows, metadata}
  end

  defp extract([_header | rest], true) do
    rows =
      rest
      |> Enum.with_index(2)
      |> Enum.map(fn {row, row_index} -> build_map_row(row, row_index) end)

    {rows, empty_metadata()}
  end

  # --- header_row: false (no header row) ---
  defp extract(content, false) when is_list(content) do
    rows =
      content
      |> Enum.with_index(1)
      |> Enum.map(fn {row, row_index} -> build_headerless_row(row, row_index) end)

    {rows, empty_metadata()}
  end

  defp extract(_content, _header_row?), do: {[], empty_metadata()}

  defp build_header_specs(headers) do
    headers
    |> Enum.with_index()
    |> Enum.map(fn {header, index} ->
      column = column_letter(index)
      key = header_key(header, column)
      {key, %{column: column, original: header}}
    end)
  end

  defp build_row(headers, row, row_index) do
    headers
    |> Enum.with_index()
    |> Map.new(fn {k, index} -> {k, row |> Enum.at(index, "") |> normalize_value()} end)
    |> Map.put("row_index", row_index)
  end

  defp build_map_row(row, row_index) do
    row
    |> stringify_keys()
    |> Map.new(fn {k, v} -> {k, normalize_value(v)} end)
    |> Map.put("row_index", row_index)
  end

  defp build_headerless_row(row, row_index) when is_list(row) do
    row
    |> Enum.with_index()
    |> Map.new(fn {v, idx} -> {column_letter(idx), normalize_value(v)} end)
    |> Map.put("row_index", row_index)
  end

  defp build_headerless_row(row, row_index) when is_map(row) do
    build_map_row(row, row_index)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k |> to_string() |> String.downcase(), v} end)

  defp stringify_keys(v), do: v

  defp header_key(nil, column), do: column

  defp header_key(header, column) when is_binary(header) do
    case String.trim(header) do
      "" -> column
      _ -> String.downcase(header)
    end
  end

  defp header_key(header, _column), do: header |> to_string() |> String.downcase()

  defp empty_metadata, do: %{headers_detected: false, headers: %{}}

  defp column_letter(index) when is_integer(index) and index >= 0 do
    do_column_letter(index + 1, "")
  end

  defp do_column_letter(0, acc), do: acc

  defp do_column_letter(index, acc) do
    remainder = rem(index - 1, 26)
    do_column_letter(div(index - 1, 26), <<?A + remainder>> <> acc)
  end

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
