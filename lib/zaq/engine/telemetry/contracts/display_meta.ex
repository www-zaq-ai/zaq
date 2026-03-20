defmodule Zaq.Engine.Telemetry.Contracts.DisplayMeta do
  @moduledoc """
  Visible metadata for telemetry visualizations.

  This struct is display-only and is safe to render in the UI.
  Supported by all BO telemetry cards/charts through their envelope structs.
  """

  @type t :: %__MODULE__{
          range: String.t() | nil,
          hint: String.t() | nil,
          scope: String.t() | nil,
          extra: map()
        }

  defstruct range: nil, hint: nil, scope: nil, extra: %{}

  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(meta) when is_map(meta) do
    %__MODULE__{
      range: map_get(meta, :range),
      hint: map_get(meta, :hint),
      scope: map_get(meta, :scope),
      extra:
        Map.drop(meta, [
          :range,
          :hint,
          :scope,
          :href,
          "range",
          "hint",
          "scope",
          "href"
        ])
    }
  end

  def from_map(_), do: %__MODULE__{}

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
