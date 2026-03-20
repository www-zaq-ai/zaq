defmodule Zaq.Engine.Telemetry.Supervisor do
  @moduledoc """
  Supervises telemetry collection and synchronization components.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Zaq.Engine.Telemetry.Buffer,
      Zaq.Engine.Telemetry.Collector
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
