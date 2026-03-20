defmodule Zaq.Engine.Telemetry.Contracts.Payloads.ScalarListPayload do
  @moduledoc """
  Collection of scalar telemetry payloads.

  Supports UI consumers that render grouped KPI cards, including:
  - metric card grids
  """

  alias Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload

  @type t :: %__MODULE__{items: [ScalarPayload.t()]}

  defstruct items: []

  @spec from_items(list()) :: t()
  def from_items(items) when is_list(items) do
    %__MODULE__{
      items:
        Enum.map(items, fn
          %ScalarPayload{} = payload -> payload
          map -> ScalarPayload.from_map(map)
        end)
    }
  end

  def from_items(_), do: %__MODULE__{}
end
