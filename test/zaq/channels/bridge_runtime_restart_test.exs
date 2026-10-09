defmodule Zaq.Channels.BridgeRuntimeRestartTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.BridgeSupervisor
  alias Zaq.Channels.Supervisor, as: ChannelsSupervisor

  defmodule RuntimeState do
    def start_link(test_pid) do
      Agent.start_link(fn ->
        send(test_pid, {:runtime_started, self()})
        :fixture
      end)
    end
  end

  test "runtime lookup follows a supervised state restart" do
    {id, initial, replacement} = restarted_runtime()
    assert ChannelsSupervisor.lookup_state_pid(id) == {:ok, replacement}
    refute Process.alive?(initial)
  end

  test "teardown stops the replacement child, not just its original PID" do
    {id, _initial, replacement} = restarted_runtime()
    assert :ok = ChannelsSupervisor.stop_bridge_runtime(%{}, id)
    refute Process.alive?(replacement)
    assert {:error, :not_running} = ChannelsSupervisor.lookup_runtime(id)
  end

  test "listener lookup and teardown follow replacement PIDs" do
    id = "listener-fixture:#{Ecto.UUID.generate()}"
    spec = %{id: id, start: {RuntimeState, :start_link, [self()]}, restart: :permanent}
    assert {:ok, %{listener_pids: [initial]}} = ChannelsSupervisor.start_runtime(id, nil, [spec])
    assert_receive {:runtime_started, ^initial}
    Process.exit(initial, :kill)
    assert_receive {:runtime_started, replacement}, 1_000
    DynamicSupervisor.which_children(BridgeSupervisor)

    on_exit(fn ->
      ChannelsSupervisor.stop_bridge_runtime(%{}, id)
      DynamicSupervisor.terminate_child(BridgeSupervisor, replacement)
    end)

    assert {:ok, %{listener_pids: [^replacement]}} = ChannelsSupervisor.lookup_runtime(id)
    assert :ok = ChannelsSupervisor.stop_bridge_runtime(%{}, id)
    refute Process.alive?(replacement)
  end

  test "failed listener startup removes child tracking and stops state" do
    id = "rollback-fixture:#{Ecto.UUID.generate()}"
    spec = %{id: id, start: {RuntimeState, :start_link, [self()]}, restart: :permanent}
    failure = %{id: :invalid, start: {Task, :start_link, [:not_a_function]}}
    assert {:error, _} = ChannelsSupervisor.start_runtime(id, spec, [failure])
    assert_receive {:runtime_started, state}
    refute Process.alive?(state)
    assert {:error, :not_running} = ChannelsSupervisor.lookup_runtime(id)
    assert [] == :ets.match_object(:zaq_channels_runtime_children, {{:runtime_child, id, :_}, :_})
  end

  test "malformed listener specs fail before starting state" do
    id = "malformed-fixture:#{Ecto.UUID.generate()}"
    spec = %{id: id, start: {RuntimeState, :start_link, [self()]}, restart: :permanent}

    assert {:error, {:invalid_child_spec, %{}}} =
             ChannelsSupervisor.start_runtime(id, spec, [%{}])

    refute_receive {:runtime_started, _}
    assert {:error, :not_running} = ChannelsSupervisor.lookup_runtime(id)
  end

  defp restarted_runtime do
    id = "restart-fixture:#{Ecto.UUID.generate()}"

    spec = %{
      id: {RuntimeState, id},
      start: {RuntimeState, :start_link, [self()]},
      restart: :permanent
    }

    assert {:ok, %{state_pid: initial}} = ChannelsSupervisor.start_runtime(id, spec, [])
    assert_receive {:runtime_started, ^initial}
    monitor = Process.monitor(initial)
    Process.exit(initial, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^initial, :killed}
    assert_receive {:runtime_started, replacement}, 1_000
    # This call is serialized after the restart callback: registration must be
    # complete before lookup/teardown assertions, without a timing sleep.
    DynamicSupervisor.which_children(BridgeSupervisor)

    on_exit(fn ->
      ChannelsSupervisor.stop_bridge_runtime(%{}, id)
      DynamicSupervisor.terminate_child(BridgeSupervisor, replacement)
    end)

    {id, initial, replacement}
  end
end
