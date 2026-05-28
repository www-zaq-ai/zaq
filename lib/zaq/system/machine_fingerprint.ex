defmodule Zaq.System.MachineFingerprint do
  @moduledoc false

  @doc """
  Returns a stable, unique identifier for this Zaq server instance.

  Derived from the endpoint's secret_key_base — unique per deployment
  and stable across restarts without requiring a separate stored value.
  Returns a 32-character lowercase hex string.
  """
  @spec get() :: String.t()
  def get do
    ZaqWeb.Endpoint.config(:secret_key_base)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end
end
