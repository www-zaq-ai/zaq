defmodule Zaq.Engine.Telemetry.Contracts.Payloads.CategoryVectorPayload do
  @moduledoc """
  Category/value telemetry payload.

  Supports UI consumers that represent categorical distributions, including:
  - bar charts
  - donut charts
  - radar charts (with optional benchmark entries)
  """

  @type entry :: %{label: String.t(), value: number()}

  @type t :: %__MODULE__{entries: [entry()], benchmark_entries: [entry()]}

  defstruct entries: [], benchmark_entries: []

  @spec from_parts(list(), list()) :: t()
  def from_parts(entries, benchmark_entries \\ []) do
    %__MODULE__{
      entries: normalize_entries(entries),
      benchmark_entries: normalize_entries(benchmark_entries)
    }
  end

  defp normalize_entries(entries) when is_list(entries) do
    Enum.map(entries, fn item ->
      %{
        label: (map_get(item, :label) || "unknown") |> to_string(),
        value:
          case map_get(item, :value) do
            value when is_integer(value) -> value * 1.0
            value when is_float(value) -> value
            _ -> 0.0
          end
      }
    end)
  end

  defp normalize_entries(_), do: []

  defp map_get(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(_, _), do: nil
end
