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

    def transform_incoming(_payload, _opts) do
      {:ok,
       %ChatIncoming{
         text: "hello",
         external_room_id: "chan-1",
         external_thread_id: nil,
         external_message_id: "msg-1",
         metadata: %{},
         was_mentioned: false,
         channel_meta: %{adapter_name: :mattermost}
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
end
