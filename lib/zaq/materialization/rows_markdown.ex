defmodule Zaq.Materialization.RowsMarkdown do
  @moduledoc """
  Renders decoded provider rows (a JSON array) as the Markdown table ingestion stores.

  One implementation serves both shapes of the same conversion:

    * `render/1` — a whole list of rows, for consumers that already hold them;
    * `new/0`, `push/2` and `done/1` — one row at a time, so a producer streaming a large JSON
      array can write each row as it is decoded without holding the array.

  Both produce byte-identical output. When the first row is a map its keys (stringified) are the
  table columns and every row is rendered against them; otherwise each row is one line.
  """

  @type t :: %__MODULE__{headers: nil | :lines | [String.t()], rows: non_neg_integer()}

  defstruct headers: nil, rows: 0

  @doc "Renders all rows, `\"\"` for none."
  @spec render([term()]) :: String.t()
  def render(rows) when is_list(rows) do
    {iodata, state} =
      Enum.reduce(rows, {[], new()}, fn row, {acc, state} ->
        {part, state} = push(state, row)
        {[acc | part], state}
      end)

    IO.iodata_to_binary([iodata | done(state)])
  end

  @doc "Starts an incremental rendering."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Renders one row; returns the iodata to append and the next state."
  @spec push(t(), term()) :: {iodata(), t()}
  def push(%__MODULE__{rows: 0} = state, row) when is_map(row) do
    headers = row |> Map.keys() |> Enum.map(&to_string/1)
    divider = Enum.map(headers, fn _ -> "---" end)

    lines = [line(headers), "\n", line(divider), "\n", row_line(row, headers)]
    {lines, %{state | headers: headers, rows: 1}}
  end

  def push(%__MODULE__{rows: 0} = state, row),
    do: {markdown_value(row), %{state | headers: :lines, rows: 1}}

  def push(%__MODULE__{headers: :lines} = state, row),
    do: {["\n", markdown_value(row)], %{state | rows: state.rows + 1}}

  def push(%__MODULE__{headers: headers} = state, row),
    do: {["\n", row_line(row, headers)], %{state | rows: state.rows + 1}}

  @doc "Trailing output once all rows were pushed (none: the output has no trailing newline)."
  @spec done(t()) :: iodata()
  def done(%__MODULE__{}), do: []

  defp row_line(row, headers) do
    headers
    |> Enum.map(fn header -> row |> row_value(header) |> markdown_value() end)
    |> line()
  end

  defp line(columns), do: ["| ", Enum.intersperse(columns, " | "), " |"]

  # Unchanged from the original conversion: a later row that is not a map raises.
  defp row_value(row, header) do
    Enum.find_value(row, "", fn {key, value} ->
      if to_string(key) == header, do: value, else: false
    end)
  end

  defp markdown_value(nil), do: ""
  defp markdown_value(value) when is_binary(value), do: value
  defp markdown_value(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp markdown_value(value) when is_list(value) or is_map(value) do
    value
    |> json_safe_value()
    |> Jason.encode!()
  end

  defp markdown_value(value), do: safe_to_string(value)

  defp json_safe_value(%_{} = value), do: value |> Map.from_struct() |> json_safe_value()

  defp json_safe_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), json_safe_value(value)} end)
  end

  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)

  defp json_safe_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp json_safe_value(value), do: safe_to_string(value)

  defp safe_to_string(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> ""
  end
end
