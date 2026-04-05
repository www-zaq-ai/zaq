defmodule Zaq.Channels.JidoChatBridge.StateTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State

  defmodule StubAdapter do
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
      if pid = Process.whereis(:state_test_observer) do
        send(pid, {:state_start_typing, channel_id, opts})
      end

      :ok
    end
  end

  setup do
    previous_channels = Application.get_env(:zaq, :channels, %{})

    Application.put_env(:zaq, :channels, %{
      mattermost: %{
        bridge: JidoChatBridge,
        adapter: StubAdapter,
        ingress_mode: :websocket
      }
    })

    config = %{
      provider: "mattermost",
      url: "https://mm.example.com",
      token: "tok",
      settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
    }

    {:ok, pid} =
      State.start_link(
        bridge_id: "mattermost_1",
        config: config,
        provider: :mattermost,
        handler_opts: %{}
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      Application.put_env(:zaq, :channels, previous_channels)
    end)

    {:ok, pid: pid, config: config}
  end

  test "process_listener_payload/4 updates state atomically", %{pid: pid, config: config} do
    assert :ok =
             State.process_listener_payload(pid, config, %{"event" => "posted"},
               transport: :websocket
             )

    state = :sys.get_state(pid)
    assert state.config.provider == "mattermost"
    assert state.bridge_id == "mattermost_1"
  end

  test "subscribe_thread/4 and unsubscribe_thread/4 mutate subscriptions", %{pid: pid} do
    assert :ok = State.subscribe_thread(pid, :mattermost, "chan-1", "thread-1")

    state = :sys.get_state(pid)
    key = JidoChatBridge.thread_key(:mattermost, "chan-1", "thread-1")
    assert MapSet.member?(state.chat.subscriptions, key)

    assert :ok = State.unsubscribe_thread(pid, :mattermost, "chan-1", "thread-1")
    state = :sys.get_state(pid)
    refute MapSet.member?(state.chat.subscriptions, key)
  end

  test "refresh_config/2 preserves runtime subscriptions", %{pid: pid, config: config} do
    assert :ok = State.subscribe_thread(pid, :mattermost, "chan-1", "thread-1")

    new_config =
      Map.put(config, :settings, %{
        "jido_chat" => %{"bot_name" => "zaq-v2", "bot_user_id" => "bot-2"}
      })

    assert :ok = State.refresh_config(pid, new_config)

    state = :sys.get_state(pid)
    key = JidoChatBridge.thread_key(:mattermost, "chan-1", "thread-1")
    assert state.chat.user_name == "zaq-v2"
    assert MapSet.member?(state.chat.subscriptions, key)
  end

  test "send_typing/4 delegates through bridge outbound API", %{pid: pid} do
    Process.register(self(), :state_test_observer)

    assert :ok =
             State.send_typing(pid, "mattermost", "chan-1", %{
               url: "https://mm.example.com",
               token: "tok"
             })

    assert_received {:state_start_typing, "chan-1", opts}
    assert opts[:url] == "https://mm.example.com"
    assert opts[:token] == "tok"

    Process.unregister(:state_test_observer)
  end
end
