defmodule Zaq.Engine.Telemetry.Contracts.Payloads.SeriesPayload do
  @moduledoc """
  Multi-point series telemetry payload.

  Supports UI consumers that render time and sequence trends, including:
  - time series charts
  - sparkline-like trend widgets
  """

  @type series_item :: %{key: String.t(), name: String.t(), values: [number()]}

  @type baseline_item :: %{
          key: String.t(),
          label: String.t(),
          value: number(),
          values: [number()]
        }

  @type t :: %__MODULE__{
          labels: [String.t()],
          series: [series_item()],
          benchmarks: map(),
          baseline: baseline_item() | nil
        }

  defstruct labels: [], series: [], benchmarks: %{}, baseline: nil

  @spec from_parts(list(), list(), map()) :: t()
  def from_parts(labels, series, benchmarks) do
    from_parts(labels, series, benchmarks, nil)
  end

  @spec from_parts(list(), list(), map(), map() | nil) :: t()
  def from_parts(labels, series, benchmarks, baseline) do
    %__MODULE__{
      labels: normalize_labels(labels),
      series: normalize_series(series),
      benchmarks: normalize_map(benchmarks),
      baseline: normalize_baseline(baseline)
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

  defp normalize_baseline(value) when is_map(value) do
    key = map_get(value, :key)
    label = map_get(value, :label)
    baseline_value = map_get(value, :value)
    values = normalize_values(map_get(value, :values) || [])

    if is_binary(key) and key != "" and is_binary(label) and label != "" and
         is_number(baseline_value) and values != [] do
      %{key: key, label: label, value: baseline_value * 1.0, values: values}
    else
      nil
    end
  end

  defp normalize_baseline(_), do: nil

  defp map_get(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(_, _), do: nil
end
