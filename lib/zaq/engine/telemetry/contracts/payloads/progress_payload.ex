defmodule Zaq.Engine.Telemetry.Contracts.Payloads.ProgressPayload do
  @moduledoc """
  Progress telemetry payload.

  Supports UI consumers that render completion/countdown states, including:
  - progress countdown cards
  """

  @type t :: %__MODULE__{total: non_neg_integer(), remaining: non_neg_integer()}

  defstruct total: 0, remaining: 0

  @spec from_values(term(), term()) :: t()
  def from_values(total, remaining) do
    %__MODULE__{total: to_int(total), remaining: to_int(remaining)}
  end

  defp to_int(value) when is_integer(value) and value >= 0, do: value
  defp to_int(value) when is_float(value) and value >= 0, do: trunc(value)
  defp to_int(_), do: 0
end
