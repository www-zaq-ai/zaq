defmodule Zaq.Engine.Telemetry.BenchmarkConnector do
  @moduledoc """
  Behaviour for benchmark telemetry synchronization.

  Implementations push local rollups to a remote service and pull benchmark
  rollups for the current organization cohort.
  """

  @type payload :: map()

  @callback push_rollups(payload()) :: :ok | {:error, term()}
  @callback pull_rollups(payload()) :: {:ok, map()} | {:error, term()}
end
