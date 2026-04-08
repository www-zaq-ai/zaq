defmodule Zaq.Channels.SupervisorTest do
  use Zaq.DataCase, async: false

  alias Jido.Chat.Incoming, as: ChatIncoming
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
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :webhook}
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
      mattermost: %{bridge: JidoChatBridge, adapter: StubAdapter, ingress_mode: :webhook}
    })

    bridge_id = "mattermost_test_already_running"
    {state_spec, listener_specs} = JidoChatBridge.runtime_specs(config, bridge_id, [])

    assert {:ok, _runtime} = Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

    assert {:error, :already_running} =
             Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

    assert :ok = Supervisor.stop_bridge_runtime(config, bridge_id)
  end

  test "stop_bridge_runtime/2 returns not_running when missing", %{config: config} do
    assert {:error, :not_running} =
             Supervisor.stop_bridge_runtime(config, "missing_bridge_runtime")
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
    if Process.alive?(prestarted), do: Process.exit(prestarted, :kill)
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
    if Process.alive?(prestarted_listener), do: Process.exit(prestarted_listener, :kill)
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

  test "stop_bridge_runtime/2 handles nil state pid" do
    bridge_id = "bridge_nil_state_stop"

    :ets.insert(:zaq_channels_listeners, {bridge_id, %{listener_pids: [], state_pid: nil}})
    assert :ok = Supervisor.stop_bridge_runtime(%{}, bridge_id)
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
  end

  test "start_link/1 returns error when supervisor is already started" do
    assert {:error, {:already_started, pid}} = Supervisor.start_link([])
    assert is_pid(pid)
  end
end
