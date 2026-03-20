defmodule Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload do
  @moduledoc """
  Scalar telemetry payload.

  Supports UI consumers that display a single metric value, including:
  - metric cards
  - gauge-like KPIs
  """

  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          label: String.t() | nil,
          value: number(),
          unit: String.t() | nil,
          trend: float() | nil,
          min: number() | nil,
          max: number() | nil,
          target: number() | nil,
          benchmark: number() | nil,
          display: DisplayMeta.t(),
          runtime: RuntimeMeta.t()
        }

  defstruct id: nil,
            label: nil,
            value: 0.0,
            unit: nil,
            trend: nil,
            min: nil,
            max: nil,
            target: nil,
            benchmark: nil,
            display: %DisplayMeta{},
            runtime: %RuntimeMeta{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    meta = Map.get(map, :meta) || Map.get(map, "meta") || %{}

    %__MODULE__{
      id: map_get(map, :id),
      label: map_get(map, :label),
      value: to_number(map_get(map, :value, 0.0)),
      unit: map_get(map, :unit),
      trend: to_optional_float(map_get(map, :trend)),
      min: to_optional_float(map_get(map, :min)),
      max: to_optional_float(map_get(map, :max)),
      target: to_optional_float(map_get(map, :target)),
      benchmark: to_optional_float(map_get(map, :benchmark_value)),
      display: DisplayMeta.from_map(Map.put(meta, :hint, map_get(map, :hint))),
      runtime: RuntimeMeta.from_map(meta)
    }
  end

  def from_map(_), do: %__MODULE__{}

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_get(map, key, default), do: map_get(map, key) || default

  defp to_number(value) when is_integer(value), do: value * 1.0
  defp to_number(value) when is_float(value), do: value
  defp to_number(_), do: 0.0

  defp to_optional_float(value) when is_integer(value), do: value * 1.0
  defp to_optional_float(value) when is_float(value), do: value
  defp to_optional_float(_), do: nil
end
