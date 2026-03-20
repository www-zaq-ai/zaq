defmodule Zaq.Engine.Telemetry.Contracts.Payloads.StatusListPayload do
  @moduledoc """
  Status list telemetry payload.

  Supports UI consumers that render stateful item grids, including:
  - status grid cards
  """

  @type item :: %{label: String.t(), status: atom() | String.t(), detail: String.t()}
  @type t :: %__MODULE__{items: [item()]}

  defstruct items: []

  @spec from_items(list()) :: t()
  def from_items(items) when is_list(items) do
    %__MODULE__{
      items:
        Enum.map(items, fn item ->
          %{
            label: (map_get(item, :label) || "Unknown") |> to_string(),
            status: map_get(item, :status) || "unknown",
            detail: (map_get(item, :detail) || "") |> to_string()
          }
        end)
    }
  end

  def from_items(_), do: %__MODULE__{}

  defp map_get(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(_, _), do: nil
end
