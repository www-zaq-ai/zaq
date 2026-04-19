defmodule Zaq.Agent.SupervisorTest do
  use ExUnit.Case, async: true

  test "agent jido registry is started" do
    registry = Jido.registry_name(Zaq.Agent.Jido)
    assert is_pid(Process.whereis(registry))
  end
end
