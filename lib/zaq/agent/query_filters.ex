defmodule Zaq.Agent.QueryFilters do
  @moduledoc false

  import Ecto.Query

  @spec maybe_filter_ilike(Ecto.Queryable.t(), String.t(), atom()) :: Ecto.Query.t()
  def maybe_filter_ilike(query, "", _field), do: query

  def maybe_filter_ilike(query, value, field) when is_binary(value) and is_atom(field) do
    escaped = escape_percent(value)
    from(row in query, where: ilike(field(row, ^field), ^"%#{escaped}%"))
  end

  defp escape_percent(value), do: String.replace(value, "%", "\\%")
end
