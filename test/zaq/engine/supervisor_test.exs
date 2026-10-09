defmodule Zaq.Engine.SupervisorTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Supervisor

  test "init/1 defines registries, service supervisors, temporary device supervision and recovery" do
    assert {:ok, {spec, children}} = Supervisor.init([])
    assert spec.strategy == :one_for_one

    assert Enum.map(children, & &1.id) == [
             Zaq.Engine.Workflows.RunRegistry,
             Zaq.Engine.Telemetry.Supervisor,
             Zaq.People.AuthRateLimiter,
             Zaq.Engine.Connect.DeviceSupervisor,
             Zaq.Engine.IngestionSupervisor,
             Zaq.Engine.RetrievalSupervisor,
             Zaq.Engine.EventRegistry,
             Zaq.Engine.Workflows.StartupRecovery
           ]

    device = Enum.find(children, &(&1.id == Zaq.Engine.Connect.DeviceSupervisor))

    assert device.start ==
             {DynamicSupervisor, :start_link,
              [[strategy: :one_for_one, name: Zaq.Engine.Connect.DeviceSupervisor]]}
  end
end
