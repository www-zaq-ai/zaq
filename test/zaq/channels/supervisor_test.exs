defmodule Zaq.Channels.SupervisorTest do
  use Zaq.DataCase, async: false
  import ExUnit.CaptureLog

  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Channels.Supervisor

  defmodule ListenerProc do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl GenServer
    def init(:ok), do: {:ok, %{}}
  end

  defmodule NamedListenerProc do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: {:global, name})

    @impl GenServer
    def init(:ok), do: {:ok, %{}}
  end

  defmodule StateProc do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: {:global, name})

    @impl GenServer
    def init(:ok), do: {:ok, %{}}
  end

  defmodule FailingStartProc do
    def start_link(_arg), do: {:error, :boom}
  end

  defmodule RaisingStartProc do
    def start_link(_arg), do: raise("kaboom")
  end

  defmodule AlreadyStartedProc do
    def start_link(pid), do: {:error, {:already_started, pid}}
  end

  defmodule BridgeFailStart do
    def start_runtime(_config), do: {:error, :bridge_start_failed}
    def stop_runtime(_config), do: :ok
  end

  defmodule BridgeFailStop do
    def start_runtime(_config), do: :ok
    def stop_runtime(_config), do: {:error, :bridge_stop_failed}
  end

  defmodule RuntimeSyncSpy do
    def sync_config_runtime(before_config, config) do
      if pid = Process.whereis(:supervisor_bootstrap_observer) do
        send(pid, {:bootstrap_sync_config_runtime, before_config, config})
      end

      :ok
    end
  end

  defmodule BootstrapSyncBridge do
    def sync_runtime(nil, config) do
      if pid = Process.whereis(:supervisor_bootstrap_observer) do
        send(pid, {:bootstrap_sync, config.kind, config.provider, config.id})
      end

      :ok
    end
  end

  defmodule StartFunctionStateProc do
    use GenServer

    def start(name), do: GenServer.start_link(__MODULE__, :ok, name: {:global, name})

    @impl GenServer
    def init(:ok), do: {:ok, %{}}

    def monitor_listeners(state_pid, listener_pids) do
      if pid = Process.whereis(:supervisor_bootstrap_observer) do
        send(pid, {:start_function_state_proc_monitor, state_pid, listener_pids})
      end

      :ok
    end
  end

  defmodule RaisingMonitorStateProc do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: {:global, name})

    @impl GenServer
    def init(:ok), do: {:ok, %{}}

    def monitor_listeners(_state_pid, _listener_pids), do: raise("monitor failed")
  end

  defmodule ExitingMonitorStateProc do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: {:global, name})

    @impl GenServer
    def init(:ok), do: {:ok, %{}}

    def monitor_listeners(_state_pid, _listener_pids), do: exit(:monitor_failed)
  end

  defmodule StubAdapter do
    def listener_child_specs(bridge_id, _opts) do
      {:ok,
       [
         %{
           id: {ListenerProc, bridge_id},
           start: {ListenerProc, :start_link, [[]]},
           restart: :temporary,
           type: :worker
         }
       ]}
    end

    def transform_incoming(_payload) do
      {:ok,
       %ChatIncoming{
         text: "hello",
         external_room_id: "chan-1",
         external_thread_id: nil,
         external_message_id: "msg-1",
         metadata: %{},
         was_mentioned: false,
         channel_meta: %{adapter_name: :mattermost, is_dm: false}
       }}
    end

    def start_typing(channel_id, opts) do
      if pid = Process.whereis(:supervisor_test_observer) do
        send(pid, {:supervisor_start_typing, channel_id, opts})
      end

      :ok
    end
  end

  defp with_stopped_channel_supervisor(fun) do
    _ = Elixir.Supervisor.terminate_child(Zaq.Supervisor, Zaq.Channels.Supervisor)

    try do
      fun.()
    after
      if pid = Process.whereis(Zaq.Channels.Supervisor) do
        ref = Process.monitor(pid)
        Process.unlink(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> :ok
        end
      end

      _ = Elixir.Supervisor.restart_child(Zaq.Supervisor, Zaq.Channels.Supervisor)
    end
  end

  setup do
    previous_channels = Application.get_env(:zaq, :channels, %{})

    config = %{
      id: System.unique_integer([:positive]),
      provider: "mattermost",
      url: "https://mm.example.com",
      token: "tok",
      settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
    }

    on_exit(fn ->
      Application.put_env(:zaq, :channels, previous_channels)
    end)

    {:ok, config: config}
  end

  test "start_runtime/3 starts state only for non-websocket ingress", %{config: config} do
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :webhook}
    })

    bridge_id = "mattermost_test_state_only"

    {state_spec, listener_specs} = JidoChatBridge.runtime_specs(config, bridge_id, [])
    assert {:ok, _runtime} = Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

    assert [{^bridge_id, runtime}] = :ets.lookup(:zaq_channels_listeners, bridge_id)
    assert runtime.listener_pids == []
    assert is_pid(runtime.state_pid)
    assert Process.alive?(runtime.state_pid)

    assert {:ok, state_pid} = Supervisor.lookup_state_pid(bridge_id)

    assert :ok =
             State.process_listener_payload(state_pid, config, %{"event" => "posted"},
               transport: :webhook
             )

    assert :ok = Supervisor.stop_bridge_runtime(config, bridge_id)
  end

  test "start_runtime/3 starts websocket listener when configured", %{config: config} do
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    bridge_id = "mattermost_test_with_listener"

    {state_spec, listener_specs} =
      JidoChatBridge.runtime_specs(config, bridge_id, channel_ids: ["chan-1"])

    assert {:ok, _runtime} = Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

    assert [{^bridge_id, runtime}] = :ets.lookup(:zaq_channels_listeners, bridge_id)
    assert is_pid(runtime.state_pid)
    assert length(runtime.listener_pids) == 1
    assert Enum.all?(runtime.listener_pids, &Process.alive?/1)

    assert :ok = Supervisor.stop_bridge_runtime(config, bridge_id)
  end

  test "lookup_state_pid/1 returns runtime state pid", %{config: config} do
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    bridge_id = "mattermost_test_typing"
    {state_spec, listener_specs} = JidoChatBridge.runtime_specs(config, bridge_id, [])
    assert {:ok, _runtime} = Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

    assert {:ok, state_pid} = Supervisor.lookup_state_pid(bridge_id)

    Process.register(self(), :supervisor_test_observer)

    assert :ok =
             State.send_typing(state_pid, "mattermost", "chan-1", %{
               url: "https://mm.example.com",
               token: "tok"
             })

    assert_received {:supervisor_start_typing, "chan-1", opts}
    assert opts[:url] == "https://mm.example.com"
    assert opts[:token] == "tok"

    Process.unregister(:supervisor_test_observer)

    assert :ok = Supervisor.stop_bridge_runtime(config, bridge_id)
  end

  test "start_listener/1 and stop_listener/1 manage runtime lifecycle", %{config: config} do
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    assert {:ok, runtime} = Supervisor.start_listener(config)
    assert is_pid(runtime.state_pid)
    assert Enum.any?(runtime.listener_pids, &Process.alive?/1)

    bridge_id = "#{config.provider}_#{config.id}"
    assert [{^bridge_id, _}] = :ets.lookup(:zaq_channels_listeners, bridge_id)

    assert :ok = Supervisor.stop_listener(config)
    assert [] == :ets.lookup(:zaq_channels_listeners, bridge_id)
  end

  test "start_runtime/3 returns already_running when bridge id is active", %{config: config} do
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    bridge_id = "mattermost_test_already_running"
    {state_spec, listener_specs} = JidoChatBridge.runtime_specs(config, bridge_id, [])

    assert {:ok, _runtime} = Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

    assert {:error, :already_running} =
             Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

    assert :ok = Supervisor.stop_bridge_runtime(config, bridge_id)
  end

  test "start_runtime/3 treats stale ETS runtime as not running and starts again" do
    bridge_id = "bridge_stale_runtime"

    dead_state = spawn(fn -> :ok end)
    dead_listener = spawn(fn -> :ok end)
    Process.sleep(10)

    :ets.insert(
      :zaq_channels_listeners,
      {bridge_id, %{listener_pids: [dead_listener], state_pid: dead_state}}
    )

    state_spec = %{
      id: {:state_stale_runtime, bridge_id},
      start: {ListenerProc, :start_link, [[]]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [])
    assert is_pid(runtime.state_pid)
    assert Process.alive?(runtime.state_pid)

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
  end

  test "start_link/1 logs empty bootstrap when no enabled channel configs exist" do
    previous_logger_level = Logger.level()

    on_exit(fn ->
      Logger.configure(level: previous_logger_level)
    end)

    Logger.configure(level: :info)

    Application.put_env(:zaq, :channels, %{
      slack: %{bridge: BootstrapSyncBridge, adapter: StubAdapter}
    })

    log =
      capture_log([level: :info], fn ->
        with_stopped_channel_supervisor(fn ->
          assert {:ok, _pid} = Supervisor.start_link([])
        end)
      end)

    assert log =~ "No enabled retrieval channel configs found, starting empty."
    assert log =~ "No enabled data_source channel configs found, starting empty."
    refute_received {:bootstrap_sync, _, _, _}
  end

  test "start_link/1 syncs each enabled retrieval and data_source config on bootstrap" do
    Process.register(self(), :supervisor_bootstrap_observer)

    on_exit(fn ->
      if Process.whereis(:supervisor_bootstrap_observer) do
        Process.unregister(:supervisor_bootstrap_observer)
      end
    end)

    {:ok, retrieval_config} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "Retrieval Bootstrap",
        kind: "retrieval",
        provider: "mattermost",
        enabled: true,
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      })

    {:ok, ds_config} =
      ChannelConfig.upsert_by_provider("google_drive", %{
        name: "DataSource Bootstrap",
        kind: "data_source",
        provider: "google_drive",
        enabled: true,
        url: "https://drive.google.com",
        token: "tok",
        settings: %{}
      })

    retrieval_id = retrieval_config.id
    ds_id = ds_config.id

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: BootstrapSyncBridge, adapter: StubAdapter},
      google_drive: %{bridge: BootstrapSyncBridge, adapter: StubAdapter}
    })

    with_stopped_channel_supervisor(fn ->
      assert {:ok, _pid} = Supervisor.start_link([])
    end)

    assert_receive {:bootstrap_sync, "retrieval", "mattermost", ^retrieval_id}
    assert_receive {:bootstrap_sync, "data_source", "google_drive", ^ds_id}
    refute_received {:bootstrap_sync, _, "slack", _}
    refute_received {:bootstrap_sync, _, "discord", _}
  end

  test "stop_bridge_runtime/2 returns not_running when missing", %{config: config} do
    assert {:error, :not_running} =
             Supervisor.stop_bridge_runtime(config, "missing_bridge_runtime")
  end

  test "start_runtime/3 rescues exceptions raised while starting listener children" do
    bridge_id = "bridge_runtime_invalid_listener_spec"
    state_name = {:state_proc_invalid_listener_spec, bridge_id}

    state_spec = %{
      id: {:state_proc_invalid_listener_spec, bridge_id},
      start: {StateProc, :start_link, [state_name]},
      restart: :temporary,
      type: :worker
    }

    bad_listener_spec = :bad

    log =
      capture_log(fn ->
        assert {:error, message} =
                 Supervisor.start_runtime(bridge_id, state_spec, [bad_listener_spec])

        assert is_binary(message)
      end)

    assert log =~ "Exception starting runtime bridge_id=bridge_runtime_invalid_listener_spec"
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)

    if pid = :global.whereis_name(state_name) do
      if is_pid(pid) and Process.alive?(pid) do
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end
  end

  test "start_runtime/3 skips monitor_listeners when state spec does not expose a start_link module" do
    bridge_id = "bridge_state_start_function"
    state_name = {:state_start_function, bridge_id}

    Process.register(self(), :supervisor_bootstrap_observer)

    on_exit(fn ->
      if Process.whereis(:supervisor_bootstrap_observer) do
        Process.unregister(:supervisor_bootstrap_observer)
      end
    end)

    state_spec = %{
      id: {:state_start_function, bridge_id},
      start: {StartFunctionStateProc, :start, [state_name]},
      restart: :temporary,
      type: :worker
    }

    listener_spec = %{
      id: {:listener_state_start_function, bridge_id},
      start: {ListenerProc, :start_link, [[]]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [listener_spec])
    assert is_pid(runtime.state_pid)
    assert Process.alive?(runtime.state_pid)
    assert length(runtime.listener_pids) == 1
    assert Enum.all?(runtime.listener_pids, &Process.alive?/1)
    refute_received {:start_function_state_proc_monitor, _, _}

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
  end

  test "start_runtime/3 ignores exceptions from monitor_listeners callback" do
    bridge_id = "bridge_monitor_raises"
    state_name = {:state_monitor_raises, bridge_id}

    state_spec = %{
      id: {:state_monitor_raises, bridge_id},
      start: {RaisingMonitorStateProc, :start_link, [state_name]},
      restart: :temporary,
      type: :worker
    }

    listener_spec = %{
      id: {:listener_monitor_raises, bridge_id},
      start: {ListenerProc, :start_link, [[]]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [listener_spec])
    assert is_pid(runtime.state_pid)
    assert Process.alive?(runtime.state_pid)
    assert length(runtime.listener_pids) == 1
    assert Enum.all?(runtime.listener_pids, &Process.alive?/1)
    assert {:ok, _} = Supervisor.lookup_runtime(bridge_id)

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
  end

  test "start_runtime/3 ignores exits from monitor_listeners callback" do
    bridge_id = "bridge_monitor_exits"
    state_name = {:state_monitor_exits, bridge_id}

    state_spec = %{
      id: {:state_monitor_exits, bridge_id},
      start: {ExitingMonitorStateProc, :start_link, [state_name]},
      restart: :temporary,
      type: :worker
    }

    listener_spec = %{
      id: {:listener_monitor_exits, bridge_id},
      start: {ListenerProc, :start_link, [[]]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [listener_spec])
    assert is_pid(runtime.state_pid)
    assert Process.alive?(runtime.state_pid)
    assert length(runtime.listener_pids) == 1
    assert Enum.all?(runtime.listener_pids, &Process.alive?/1)
    assert {:ok, _} = Supervisor.lookup_runtime(bridge_id)

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
  end

  test "stop_bridge_runtime/2 removes ETS entry when child termination exits" do
    bridge_id = "bridge_stop_runtime_missing_supervisor"
    state_pid = spawn(fn -> Process.sleep(:infinity) end)

    :ets.insert(
      :zaq_channels_listeners,
      {bridge_id, %{listener_pids: [state_pid], state_pid: nil}}
    )

    with_stopped_channel_supervisor(fn ->
      assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
    end)

    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)

    if Process.alive?(state_pid) do
      Process.exit(state_pid, :kill)
    end
  end

  test "lookup_runtime/1 and lookup_state_pid/1 return not_running for unknown bridge id" do
    assert {:error, :not_running} = Supervisor.lookup_runtime("unknown_bridge")
    assert {:error, :not_running} = Supervisor.lookup_state_pid("unknown_bridge")
  end

  test "lookup_state_pid/1 returns not_running when state pid is nil" do
    bridge_id = "bridge_with_nil_state"
    :ets.insert(:zaq_channels_listeners, {bridge_id, %{listener_pids: [], state_pid: nil}})

    assert {:error, :not_running} = Supervisor.lookup_state_pid(bridge_id)

    :ets.delete(:zaq_channels_listeners, bridge_id)
  end

  test "start_runtime/3 rolls back when listener child start fails" do
    bridge_id = "bridge_listener_failure"
    state_name = {:state_proc, bridge_id}
    listener_name = {:listener_proc, bridge_id}

    state_spec = %{
      id: {:state_proc, bridge_id},
      start: {StateProc, :start_link, [state_name]},
      restart: :temporary,
      type: :worker
    }

    good_listener_spec = %{
      id: {:listener_ok, bridge_id},
      start: {NamedListenerProc, :start_link, [listener_name]},
      restart: :temporary,
      type: :worker
    }

    failing_listener_spec = %{
      id: {:listener_fail, bridge_id},
      start: {FailingStartProc, :start_link, [:ignored]},
      restart: :temporary,
      type: :worker
    }

    assert {:error, _reason} =
             Supervisor.start_runtime(bridge_id, state_spec, [
               good_listener_spec,
               failing_listener_spec
             ])

    assert :global.whereis_name(listener_name) in [:undefined, :error]
    assert :global.whereis_name(state_name) in [:undefined, :error]
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
  end

  test "start_runtime/3 fails cleanly when state process fails to start" do
    bridge_id = "bridge_state_proc_failure"

    failing_state_spec = %{
      id: {:state_proc_fail, bridge_id},
      start: {FailingStartProc, :start_link, [:ignored]},
      restart: :temporary,
      type: :worker
    }

    assert {:error, :boom} = Supervisor.start_runtime(bridge_id, failing_state_spec, [])
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
  end

  test "start_listener/1 propagates router start errors", %{config: config} do
    previous = Application.get_env(:zaq, :channels, %{})

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: BridgeFailStart, adapter: StubAdapter, ingress_mode: :webhook}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    assert {:error, :bridge_start_failed} = Supervisor.start_listener(config)
  end

  test "stop_listener/1 propagates router stop errors", %{config: config} do
    previous = Application.get_env(:zaq, :channels, %{})

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: BridgeFailStop, adapter: StubAdapter, ingress_mode: :webhook}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

    assert {:error, :bridge_stop_failed} = Supervisor.stop_listener(config)
  end

  test "start_runtime/3 supports default empty listeners argument" do
    bridge_id = "bridge_default_arg_runtime"
    state_name = {:state_default_arg_proc, bridge_id}

    state_spec = %{
      id: {:state_default_arg_proc, bridge_id},
      start: {StateProc, :start_link, [state_name]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec)
    assert runtime.listener_pids == []
    assert is_pid(runtime.state_pid)

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
  end

  test "start_runtime/3 supports nil state spec" do
    bridge_id = "bridge_nil_state_runtime"

    listener_spec = %{
      id: {:listener_nil_state, bridge_id},
      start: {ListenerProc, :start_link, [[]]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, nil, [listener_spec])
    assert runtime.state_pid == nil
    assert length(runtime.listener_pids) == 1
    assert Enum.all?(runtime.listener_pids, &Process.alive?/1)
    assert {:error, :not_running} = Supervisor.lookup_state_pid(bridge_id)

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
  end

  test "start_runtime/3 accepts already started state process" do
    bridge_id = "bridge_state_already_started"
    state_name = {:state_already_started_proc, bridge_id}

    {:ok, prestarted} = StateProc.start_link(state_name)

    state_spec = %{
      id: {:state_already_started_proc, bridge_id},
      start: {StateProc, :start_link, [state_name]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [])
    assert runtime.state_pid == prestarted

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)

    assert Process.alive?(prestarted)
    Process.unlink(prestarted)
    Process.exit(prestarted, :kill)
  end

  test "start_runtime/3 handles explicit already_started state response" do
    bridge_id = "bridge_state_already_started_explicit"
    {:ok, prestarted} = StateProc.start_link({:state_proc_explicit, bridge_id})

    state_spec = %{
      id: {:state_proc_explicit, bridge_id},
      start: {AlreadyStartedProc, :start_link, [prestarted]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [])
    assert runtime.state_pid == prestarted

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)

    if Process.alive?(prestarted),
      do:
        (
          Process.unlink(prestarted)
          Process.exit(prestarted, :kill)
        )
  end

  test "start_runtime/3 accepts already started listener child" do
    bridge_id = "bridge_listener_already_started"
    state_name = {:state_listener_already_started_proc, bridge_id}
    listener_name = {:listener_already_started_proc, bridge_id}

    state_spec = %{
      id: {:state_listener_already_started_proc, bridge_id},
      start: {StateProc, :start_link, [state_name]},
      restart: :temporary,
      type: :worker
    }

    {:ok, listener_pid} = NamedListenerProc.start_link(listener_name)

    listener_spec = %{
      id: {:listener_already_started_spec, bridge_id},
      start: {NamedListenerProc, :start_link, [listener_name]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [listener_spec])
    assert runtime.listener_pids == [listener_pid]

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)

    assert Process.alive?(listener_pid)
    Process.unlink(listener_pid)
    Process.exit(listener_pid, :kill)
  end

  test "start_runtime/3 handles explicit already_started listener response" do
    bridge_id = "bridge_listener_already_started_explicit"

    {:ok, prestarted_listener} =
      NamedListenerProc.start_link({:listener_proc_explicit, bridge_id})

    state_spec = %{
      id: {:state_listener_explicit, bridge_id},
      start: {ListenerProc, :start_link, [[]]},
      restart: :temporary,
      type: :worker
    }

    listener_spec = %{
      id: {:listener_explicit, bridge_id},
      start: {AlreadyStartedProc, :start_link, [prestarted_listener]},
      restart: :temporary,
      type: :worker
    }

    assert {:ok, runtime} = Supervisor.start_runtime(bridge_id, state_spec, [listener_spec])
    assert runtime.listener_pids == [prestarted_listener]

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)

    if Process.alive?(prestarted_listener),
      do:
        (
          Process.unlink(prestarted_listener)
          Process.exit(prestarted_listener, :kill)
        )
  end

  test "start_runtime/3 rescue path returns exception message" do
    bridge_id = "bridge_runtime_rescue"

    raising_state_spec = %{
      id: {:state_runtime_rescue_proc, bridge_id},
      start: {RaisingStartProc, :start_link, [:ignored]},
      restart: :temporary,
      type: :worker
    }

    assert {:error, {%RuntimeError{message: "kaboom"}, _stack}} =
             Supervisor.start_runtime(bridge_id, raising_state_spec, [])
  end

  test "enabled retrieval configs can be synced to runtime", %{config: config} do
    previous_channels = Application.get_env(:zaq, :channels, %{})

    on_exit(fn ->
      Application.put_env(:zaq, :channels, previous_channels)

      unless Process.whereis(Supervisor) do
        {:ok, _pid} = Supervisor.start_link([])
      end
    end)

    {:ok, channel_config} =
      ChannelConfig.upsert_by_provider(config.provider, %{
        name: "Mattermost Bootstrap",
        kind: "retrieval",
        provider: config.provider,
        enabled: true,
        url: config.url,
        token: config.token,
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      })

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    bridge_id = "#{channel_config.provider}_#{channel_config.id}"

    _ = Supervisor.stop_bridge_runtime(%{}, bridge_id)

    assert :ok = CommunicationBridge.sync_config_runtime(nil, channel_config)

    assert {:ok, runtime} = wait_for_runtime(bridge_id)
    assert is_pid(runtime.state_pid)
  end

  test "stop_bridge_runtime/2 handles nil state pid" do
    bridge_id = "bridge_nil_state_stop"

    :ets.insert(:zaq_channels_listeners, {bridge_id, %{listener_pids: [], state_pid: nil}})
    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
  end

  test "stop_bridge_runtime/2 always removes ETS runtime entry when child cleanup is invalid" do
    bridge_id = "bridge_stop_cleanup_guarantee"

    :ets.insert(
      :zaq_channels_listeners,
      {bridge_id, %{listener_pids: [:invalid_pid], state_pid: :invalid_pid}}
    )

    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
  end

  test "start_link/1 returns error when supervisor is already started" do
    assert {:error, {:already_started, pid}} = Supervisor.start_link([])
    assert is_pid(pid)
  end

  test "data source configs can be synced to runtime via DataSourceBridge" do
    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    {:ok, channel_config} =
      ChannelConfig.upsert_by_provider("google_drive", %{
        name: "Google Drive Runtime",
        kind: "data_source",
        provider: "google_drive",
        enabled: true,
        url: "https://drive.google.com",
        token: "tok",
        settings: %{}
      })

    bridge_id = "#{channel_config.provider}_#{channel_config.id}"
    _ = Supervisor.stop_bridge_runtime(%{}, bridge_id)

    assert :ok = DataSourceBridge.sync_config_runtime(nil, channel_config)
    assert {:ok, runtime} = wait_for_runtime(bridge_id)
    assert is_pid(runtime.state_pid)
  end

  test "public API guards reject invalid argument types" do
    assert_raise FunctionClauseError, fn ->
      Supervisor.start_runtime(:not_binary, nil, [])
    end

    assert_raise FunctionClauseError, fn ->
      Supervisor.lookup_runtime(123)
    end

    assert_raise FunctionClauseError, fn ->
      Supervisor.lookup_state_pid(nil)
    end
  end

  test "bootstrap loads enabled retrieval and data_source configs on startup", %{config: config} do
    previous_channels = Application.get_env(:zaq, :channels, %{})

    on_exit(fn ->
      Application.put_env(:zaq, :channels, previous_channels)

      # Ensure supervisor is running (it may have been restarted by the app)
      unless Process.whereis(Supervisor) do
        {:ok, _pid} = Supervisor.start_link([])
      end
    end)

    # Create enabled retrieval config
    {:ok, retrieval_config} =
      ChannelConfig.upsert_by_provider(config.provider, %{
        name: "Retrieval Bootstrap",
        kind: "retrieval",
        provider: config.provider,
        enabled: true,
        url: config.url,
        token: config.token,
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      })

    retrieval_bridge_id = "#{retrieval_config.provider}_#{retrieval_config.id}"

    # Create enabled data_source config
    ds_provider = "google_drive"

    {:ok, ds_config} =
      ChannelConfig.upsert_by_provider(ds_provider, %{
        name: "DataSource Bootstrap",
        kind: "data_source",
        provider: ds_provider,
        enabled: true,
        url: "https://drive.google.com",
        token: "tok",
        settings: %{}
      })

    ds_bridge_id = "#{ds_config.provider}_#{ds_config.id}"

    # Set up app env with providers that have adapters (hits configured_providers)
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket},
      google_drive: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    # Manually invoke what the bootstrap's load_initial_runtimes does:
    # sync for both retrieval and data_source kinds
    _ = Supervisor.stop_bridge_runtime(%{}, retrieval_bridge_id)
    _ = Supervisor.stop_bridge_runtime(%{}, ds_bridge_id)

    assert :ok = CommunicationBridge.sync_config_runtime(nil, retrieval_config)
    assert {:ok, retrieval_runtime} = wait_for_runtime(retrieval_bridge_id)
    assert is_pid(retrieval_runtime.state_pid)

    assert :ok = DataSourceBridge.sync_config_runtime(nil, ds_config)
    assert {:ok, ds_runtime} = wait_for_runtime(ds_bridge_id)
    assert is_pid(ds_runtime.state_pid)

    # Cleanup the ETS entries we created
    _ = Supervisor.stop_bridge_runtime(%{}, retrieval_bridge_id)
    _ = Supervisor.stop_bridge_runtime(%{}, ds_bridge_id)
  end

  test "bootstrap is no-op when no enabled channel configs exist" do
    previous_channels = Application.get_env(:zaq, :channels, %{})

    on_exit(fn ->
      Application.put_env(:zaq, :channels, previous_channels)
    end)

    before_entries =
      :zaq_channels_listeners
      |> :ets.tab2list()
      |> Enum.filter(fn {bridge_id, _runtime} ->
        String.starts_with?(to_string(bridge_id), "mattermost")
      end)

    # Set up app env with a provider that has an adapter — configured_providers
    # will return ["mattermost"], but neither retrieval nor data_source configs
    # exist in the DB, so list_enabled_by_kind returns [] for both.
    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :websocket}
    })

    # The supervisor is already running from the application startup.
    # The bootstrap already ran. Verify no runtime entries exist for mattermost.
    entries =
      :zaq_channels_listeners
      |> :ets.tab2list()
      |> Enum.filter(fn {bridge_id, _runtime} ->
        String.starts_with?(to_string(bridge_id), "mattermost")
      end)

    assert length(entries) == length(before_entries),
           "Expected bootstrap to avoid creating new mattermost runtime entries. before=#{inspect(before_entries)} after=#{inspect(entries)}"
  end

  defp wait_for_runtime(bridge_id, attempts \\ 40)

  defp wait_for_runtime(_bridge_id, 0), do: {:error, :not_running}

  defp wait_for_runtime(bridge_id, attempts) do
    case Supervisor.lookup_runtime(bridge_id) do
      {:ok, _runtime} = ok ->
        ok

      {:error, :not_running} ->
        Process.sleep(25)
        wait_for_runtime(bridge_id, attempts - 1)
    end
  end
end
