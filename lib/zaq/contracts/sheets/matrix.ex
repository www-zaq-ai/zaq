defmodule Zaq.Contracts.Sheets.Matrix do
  @moduledoc "Composable helpers for canonical sheet matrices."

  alias Zaq.Contracts.Sheets.Coercion

  @spec normalize(term()) :: [[String.t() | number() | boolean() | nil]]
  def normalize(values) when is_list(values) do
    values
    |> Enum.map(fn
      row when is_list(row) -> Enum.map(row, &Coercion.scalar/1)
      other -> [Coercion.scalar(other)]
    end)
  end

  def normalize(_), do: []

  @spec append_rows([[term()]], [[term()]]) :: [[String.t() | number() | boolean() | nil]]
  def append_rows(values, rows), do: normalize(values) ++ normalize(rows)
end
