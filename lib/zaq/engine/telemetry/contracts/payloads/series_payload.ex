defmodule Zaq.Engine.Telemetry.Contracts.Payloads.SeriesPayload do
  @moduledoc """
  Multi-point series telemetry payload.

  Supports UI consumers that render time and sequence trends, including:
  - time series charts
  - sparkline-like trend widgets
  """

  @type series_item :: %{key: String.t(), name: String.t(), values: [number()]}

  @type t :: %__MODULE__{
          labels: [String.t()],
          series: [series_item()],
          benchmarks: map()
        }

  defstruct labels: [], series: [], benchmarks: %{}

  @spec from_parts(list(), list(), map()) :: t()
  def from_parts(labels, series, benchmarks) do
    %__MODULE__{
      labels: normalize_labels(labels),
      series: normalize_series(series),
      benchmarks: normalize_map(benchmarks)
    }
  end

  defp normalize_labels(labels) when is_list(labels), do: Enum.map(labels, &to_string/1)
  defp normalize_labels(_), do: []

  defp normalize_series(series) when is_list(series) do
    Enum.map(series, fn item ->
      %{
        key: map_get(item, :key) || "series",
        name: map_get(item, :name) || map_get(item, :key) || "Series",
        values: normalize_values(map_get(item, :values) || [])
      }
    end)
  end

  defp normalize_series(_), do: []

  defp normalize_values(values) when is_list(values) do
    Enum.map(values, fn
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _ -> 0.0
    end)
  end

  defp normalize_values(_), do: []
  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp map_get(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(_, _), do: nil
end
