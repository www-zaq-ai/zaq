defmodule Zaq.Channels.BridgeRuntimeRestartTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.BridgeSupervisor
  alias Zaq.Channels.Supervisor, as: ChannelsSupervisor

  setup tags do
    Zaq.DataCase.setup_sandbox(tags)

    # Each crash scenario needs fresh restart budgets, including when another
    # module has just exercised the application's shared supervision tree.
    # Registered after sandbox setup so teardown still has database ownership.
    on_exit(fn -> reset_channels_supervisor() end)
    reset_channels_supervisor()
    :ok
  end

  defmodule RuntimeState do
    def start_link(test_pid) do
      Agent.start_link(fn ->
        send(test_pid, {:runtime_started, self()})
        :fixture
      end)
    end
  end

  defmodule ExtraInfoState do
    def start_link(owner) do
      {:ok, pid} = RuntimeState.start_link(owner)
      {:ok, pid, :startup_info}
    end
  end

  test "OTP extra-info results use the same state and listener tracking" do
    id = "extra-info-fixture:#{Ecto.UUID.generate()}"
    spec = %{id: id, start: {ExtraInfoState, :start_link, [self()]}, restart: :permanent}

    assert {:ok, %{state_pid: state, listener_pids: [listener]}} =
             ChannelsSupervisor.start_runtime(id, spec, [spec])

    on_exit(fn -> ChannelsSupervisor.stop_bridge_runtime(%{}, id) end)
    assert_receive {:runtime_started, ^state}
    assert_receive {:runtime_started, ^listener}
    assert state != listener
    assert :ok = ChannelsSupervisor.stop_bridge_runtime(%{}, id)
    refute Process.alive?(state)
    refute Process.alive?(listener)
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
    on_exit(fn -> ChannelsSupervisor.stop_bridge_runtime(%{}, id) end)
    assert_receive {:runtime_started, ^initial}
    Process.exit(initial, :kill)
    assert_receive {:runtime_started, replacement}, 1_000
    DynamicSupervisor.which_children(BridgeSupervisor)

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
    on_exit(fn -> ChannelsSupervisor.stop_bridge_runtime(%{}, id) end)
    assert_receive {:runtime_started, ^initial}
    monitor = Process.monitor(initial)
    Process.exit(initial, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^initial, :killed}
    assert_receive {:runtime_started, replacement}, 1_000
    # This call is serialized after the restart callback: registration must be
    # complete before lookup/teardown assertions, without a timing sleep.
    DynamicSupervisor.which_children(BridgeSupervisor)

    {id, initial, replacement}
  end

  defp reset_channels_supervisor do
    :ok = Supervisor.terminate_child(Zaq.Supervisor, ChannelsSupervisor)
    assert {:ok, _pid} = Supervisor.restart_child(Zaq.Supervisor, ChannelsSupervisor)
  end
end
