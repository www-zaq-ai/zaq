defmodule Zaq.Channels.SupervisionTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.BridgeSupervisor
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.PeopleAuthRateLimiter, as: Ingress
  alias Zaq.Channels.Supervisor, as: Channels
  alias Zaq.TestSupport.Channels.RuntimeAdapterStub, as: StubAdapter

  setup do
    previous = Application.get_env(:zaq, :channels)
    Application.put_env(:zaq, :channels, %{})
    # Each crash scenario gets its own restart budget and resource ownership.
    :ok = Supervisor.terminate_child(Zaq.Supervisor, Channels)
    {:ok, _} = Supervisor.restart_child(Zaq.Supervisor, Channels)

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    :ok
  end

  test "static parent starts limiter before dynamic bridge owner and retains role discovery" do
    assert {:ok, {%{strategy: :one_for_one}, specs}} = Channels.init([])
    assert Enum.map(specs, & &1.id) == [Ingress, BridgeSupervisor]

    children = Supervisor.which_children(Channels)
    assert length(children) == 2

    for module <- [Ingress, BridgeSupervisor] do
      assert {^module, pid, :supervisor, [^module]} = List.keyfind(children, module, 0)
      assert pid == Process.whereis(module)
    end

    assert :ets.info(:zaq_channels_listeners, :owner) == Process.whereis(Channels)
    assert Zaq.NodeRouter.supervisor_map().channels == Channels
    assert Zaq.NodeRouter.find_node(Channels) == node()
  end

  test "bridge supervisor crash reloads configured runtimes and preserves limiter counters" do
    bridge_id = configured_runtime()
    assert {:ok, old_runtime} = Channels.lookup_runtime(bridge_id)
    ingress = Process.whereis(Ingress)
    cache = Process.whereis(Ingress.Config)
    table = :ets.whereis(:zaq_channels_listeners)
    ip = exhaust_identification_budget()
    old_bridge = Process.whereis(BridgeSupervisor)
    {:ok, specs} = StubAdapter.listener_child_specs("ephemeral", [])
    assert {:ok, ephemeral} = Channels.start_runtime("ephemeral", nil, specs)

    crash_child(Channels, BridgeSupervisor, runtime_pids(old_runtime) ++ ephemeral.listener_pids)

    refute Process.whereis(BridgeSupervisor) == old_bridge
    assert Process.whereis(Ingress) == ingress
    assert Process.whereis(Ingress.Config) == cache
    assert :ets.whereis(:zaq_channels_listeners) == table
    assert [] == :ets.lookup(:zaq_channels_listeners, "ephemeral")
    assert {:error, :not_running} = Channels.lookup_runtime("ephemeral")
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    assert_reloaded(bridge_id, old_runtime)
  end

  test "limiter supervisor crash resets its local resources without restarting bridge runtimes" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    bridge = Process.whereis(BridgeSupervisor)
    ingress = Process.whereis(Ingress)
    cache = Process.whereis(Ingress.Config)
    ip = exhaust_identification_budget()

    crash_child(Channels, Ingress, ingress_children())

    refute Process.whereis(Ingress) == ingress
    refute Process.whereis(Ingress.Config) == cache
    assert Process.whereis(BridgeSupervisor) == bridge
    assert Channels.lookup_runtime(bridge_id) == {:ok, runtime}
    _ = :sys.get_state(runtime.state_pid)
    refresh_config()
    assert :ok = Ingress.check_identification(ip)
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  test "parent crash stops both subtrees and recreates ETS before bootstrapping" do
    bridge_id = configured_runtime()
    assert {:ok, old_runtime} = Channels.lookup_runtime(bridge_id)
    old_parent = Process.whereis(Channels)
    old_table = :ets.whereis(:zaq_channels_listeners)

    descendants =
      [Process.whereis(BridgeSupervisor), Process.whereis(Ingress)] ++
        ingress_children() ++ runtime_pids(old_runtime)

    crash_child(Zaq.Supervisor, Channels, descendants)

    refute Process.whereis(Channels) == old_parent
    refute :ets.whereis(:zaq_channels_listeners) == old_table
    assert :ets.info(:zaq_channels_listeners, :owner) == Process.whereis(Channels)
    assert_reloaded(bridge_id, old_runtime)
    refresh_config()
    assert {:ok, _} = Ingress.Config.get()
  end

  test "parent shutdown removes resources and missing-table lookups retain not_running contract" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)

    refs =
      monitor_all([
        Process.whereis(Ingress),
        Process.whereis(BridgeSupervisor) | runtime_pids(runtime)
      ])

    assert :ok = Supervisor.terminate_child(Zaq.Supervisor, Channels)

    try do
      assert_down(refs)
      assert :undefined == :ets.whereis(:zaq_channels_listeners)
      assert {:error, :not_running} = Channels.lookup_runtime(bridge_id)
      assert {:error, :not_running} = Channels.lookup_state_pid(bridge_id)
      assert {:error, :not_running} = Channels.stop_bridge_runtime(%{}, bridge_id)
      assert nil == Zaq.NodeRouter.find_node(Channels)
    after
      assert {:ok, _} = Supervisor.restart_child(Zaq.Supervisor, Channels)
    end

    assert_reloaded(bridge_id, runtime)
  end

  test "bridge child shutdown retains the parent table but never returns dead runtime pids" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    refs = monitor_all(runtime_pids(runtime))
    table = :ets.whereis(:zaq_channels_listeners)
    assert :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    try do
      assert_down(refs)
      assert :ets.whereis(:zaq_channels_listeners) == table
      assert {:error, :not_running} = Channels.lookup_runtime(bridge_id)
      assert {:error, :not_running} = Channels.lookup_state_pid(bridge_id)
      assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
      assert {:error, :not_running} = Channels.stop_bridge_runtime(%{}, bridge_id)
      assert Zaq.NodeRouter.find_node(Channels) == node()
    after
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end

    assert_reloaded(bridge_id, runtime)
  end

  test "OTP abnormal termination restarts each child independently without pausing its parent" do
    bridge_id = configured_runtime()
    assert {:ok, old_runtime} = Channels.lookup_runtime(bridge_id)
    parent = Process.whereis(Channels)
    ingress = Process.whereis(Ingress)
    bridge = Process.whereis(BridgeSupervisor)
    ip = exhaust_identification_budget()

    :ok = Supervisor.stop(bridge, :runtime_failure)
    children = Supervisor.which_children(Channels)

    assert {BridgeSupervisor, new_bridge, :supervisor, _} =
             List.keyfind(children, BridgeSupervisor, 0)

    refute new_bridge == bridge
    assert is_pid(new_bridge)
    assert Process.whereis(Ingress) == ingress
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    refute runtime.state_pid == old_runtime.state_pid

    :ok = Supervisor.stop(ingress, :limiter_failure)
    children = Supervisor.which_children(Channels)
    assert {Ingress, new_ingress, :supervisor, _} = List.keyfind(children, Ingress, 0)
    refute new_ingress == ingress
    assert is_pid(new_ingress)
    assert Process.whereis(Channels) == parent
    assert Process.whereis(BridgeSupervisor) == new_bridge
    assert Channels.lookup_runtime(bridge_id) == {:ok, runtime}
    refresh_config()
    assert :ok = Ingress.check_identification(ip)
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  test "a stopped state is not returned even when a listener remains alive" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    ref = Process.monitor(runtime.state_pid)
    assert :ok = DynamicSupervisor.terminate_child(BridgeSupervisor, runtime.state_pid)
    assert_receive {:DOWN, ^ref, :process, _, :shutdown}
    assert {:ok, _} = Channels.lookup_runtime(bridge_id)
    assert {:error, :not_running} = Channels.lookup_state_pid(bridge_id)
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  test "duplicate dynamic starts preserve active runtime entries" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    bridge = Process.whereis(BridgeSupervisor)
    assert {:error, {:already_started, ^bridge}} = BridgeSupervisor.start_link([])
    assert Channels.lookup_runtime(bridge_id) == {:ok, runtime}
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  test "processless runtimes preserve the empty runtime return contract" do
    assert {:ok, %{listener_pids: [], state_pid: nil} = runtime} =
             Channels.start_runtime("empty", nil)

    assert Channels.lookup_runtime("empty") == {:ok, runtime}
    assert {:error, :not_running} = Channels.lookup_state_pid("empty")
    assert :ok = Channels.stop_bridge_runtime(%{}, "empty")
  end

  defp configured_runtime do
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    {:ok, config} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "Supervision lifecycle",
        kind: "retrieval",
        provider: "mattermost",
        enabled: true,
        url: "https://mm.example.com",
        token: "test-token",
        settings: %{}
      })

    assert {:ok, _} = Channels.start_listener(config)
    "mattermost_#{config.id}"
  end

  defp assert_reloaded(bridge_id, old) do
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    refute runtime.state_pid == old.state_pid
    assert [_] = runtime.listener_pids
    refute runtime.listener_pids == old.listener_pids
    assert Channels.lookup_state_pid(bridge_id) == {:ok, runtime.state_pid}
    children = DynamicSupervisor.which_children(BridgeSupervisor)
    assert Enum.all?(runtime_pids(runtime), &List.keymember?(children, &1, 1))
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  defp exhaust_identification_budget do
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    refresh_config()
    unique = System.unique_integer([:positive])
    ip = {0, 0, 0, 0, 0, 0, div(unique, 65_536), rem(unique, 65_536)}
    assert :ok = Ingress.record_failed_identification(ip)
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    ip
  end

  defp refresh_config do
    send(Ingress.Config, :refresh)
    _ = :sys.get_state(Ingress.Config)
  end

  defp runtime_pids(runtime), do: [runtime.state_pid | runtime.listener_pids]

  defp ingress_children do
    [
      Process.whereis(Ingress.Config),
      Process.whereis(Ingress.Runtime),
      Process.whereis(Ingress.Listener),
      :ets.info(Ingress.Local, :owner)
    ]
  end

  defp crash_child(parent, child, descendants) do
    pid = Process.whereis(child)
    refs = monitor_all([pid | descendants])
    # :kill bypasses OTP terminate callbacks. Hold restart until all linked
    # descendants release their registered names; monitor every subtree process.
    # The separate abnormal-termination test exercises unpaused OTP recovery.
    :ok = :sys.suspend(parent)

    try do
      Process.exit(pid, :kill)
      assert_down(refs)
    after
      :ok = :sys.resume(parent)
    end

    # Ordinary supervisor call is processed after the queued child exit/restart.
    assert {^child, new_pid, :supervisor, _} =
             parent |> Supervisor.which_children() |> List.keyfind(child, 0)

    refute new_pid == pid
    assert is_pid(new_pid)
  end

  defp monitor_all(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp assert_down(refs) do
    for {pid, ref} <- refs do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end
end
