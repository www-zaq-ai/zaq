defmodule Zaq.Channels.JidoChatBridge.StateTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.EventEnvelope
  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Jido.Chat.ReactionEvent
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Engine.Messages.Outgoing

  # Observes what `Jido.Chat` hands the registered `on_reaction` callback, while
  # delegating everything else the state process needs to the real bridge.
  #
  # Reaction ingress reaches the handler through `Chat.route_event/4`, so a stub
  # on `handle_reaction_event/2` would never fire — `register_handlers/3` closes
  # over the bridge's own local function. Registering an observing handler is the
  # only way to see the normalized event without also running the rating dispatch.
  defmodule StubBridge do
    defdelegate adapter_for(provider), to: JidoChatBridge
    defdelegate runtime_chat_module(), to: JidoChatBridge
    defdelegate provider_to_atom(provider), to: JidoChatBridge
    defdelegate thread_key(provider, channel_id, thread_id), to: JidoChatBridge

    def register_handlers(chat, config, _handler_opts) do
      Jido.Chat.on_reaction(chat, fn _thread, reaction ->
        if pid = Process.whereis(:state_test_observer) do
          send(pid, {:state_handle_reaction, config, reaction})
        end

        :ok
      end)
    end
  end

  defmodule StubAdapter do
    def transform_incoming(payload) do
      if pid = Process.whereis(:state_test_observer) do
        send(pid, {:state_transform_incoming, payload})
      end

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
      if pid = Process.whereis(:state_test_observer) do
        send(pid, {:state_start_typing, channel_id, opts})
      end

      :ok
    end

    def add_reaction(channel_id, message_id, emoji, opts) do
      if pid = Process.whereis(:state_test_observer) do
        send(pid, {:state_add_reaction, channel_id, message_id, emoji, opts})
      end

      :ok
    end

    def remove_reaction(channel_id, message_id, emoji, opts) do
      if pid = Process.whereis(:state_test_observer) do
        send(pid, {:state_remove_reaction, channel_id, message_id, emoji, opts})
      end

      :ok
    end
  end

  defmodule StubChatModuleInvalidWebhookState do
    def handle_webhook_request(_chat, _provider, _request, _opts) do
      {:ok, :invalid_chat_state, :noop, %{status: 200, headers: %{}, body: "ok"}}
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

  # Mirrors the envelope shape gateway/polling workers push into the sink.
  defp reaction_envelope(overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          adapter_name: :mattermost,
          thread_id: "mattermost:chan-1",
          message_id: "msg-1",
          emoji: "thumbsup",
          added: true,
          user: %{user_id: "user-1"},
          raw: %{},
          metadata: %{channel_id: "chan-1"}
        },
        overrides
      )

    EventEnvelope.new(%{
      adapter_name: :mattermost,
      event_type: :reaction,
      thread_id: "mattermost:chan-1",
      channel_id: "chan-1",
      message_id: "msg-1",
      payload: payload,
      raw: %{},
      metadata: %{}
    })
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

  test "process_listener_payload/4 marks ingress ok after usable payload", %{
    pid: pid,
    config: config
  } do
    assert :ok =
             State.process_listener_payload(pid, config, %{"event" => "posted"},
               transport: :websocket
             )

    assert %{status: :ok} = State.ingress_status(pid)
  end

  test "record_ingress_status/2 stores status with timestamp", %{pid: pid} do
    status = %{status: :pending, summary: "connecting"}

    assert :ok = State.record_ingress_status(pid, status)
    :sys.get_state(pid)

    assert %{status: :pending, summary: "connecting", updated_at: %DateTime{}} =
             State.ingress_status(pid)
  end

  test "monitor_listeners/2 records normalized listener crash errors", %{pid: pid} do
    listener =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    State.monitor_listeners(pid, [listener])
    :sys.get_state(pid)

    Process.exit(listener, {:auth_failed, :invalid_token})

    assert_eventually(fn ->
      assert %{status: :error, reason: :invalid_token, summary: summary} =
               State.ingress_status(pid)

      assert summary =~ "authentication failed"
    end)
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

  test "process_webhook_request/3 returns unsupported_provider when provider cannot be atomized",
       %{pid: pid, config: config} do
    unsupported_config = %{config | provider: "no-such-provider"}

    payload = %{"method" => "POST", "path" => "/channels/webhook/conversation/no-such-provider"}

    before_state = :sys.get_state(pid)

    assert {:error, :unsupported_provider} =
             State.process_webhook_request(pid, unsupported_config, payload)

    assert :sys.get_state(pid).chat == before_state.chat
  end

  test "process_webhook_request/3 returns adapter error for atom provider without adapter",
       %{pid: pid, config: config} do
    unsupported_adapter_config = %{config | provider: :no_such_provider}

    payload = %{"method" => "POST", "path" => "/channels/webhook/conversation/no_such_provider"}

    before_state = :sys.get_state(pid)

    assert {:error, :unsupported_provider} =
             State.process_webhook_request(pid, unsupported_adapter_config, payload)

    assert :sys.get_state(pid).chat == before_state.chat
  end

  test "refresh_config/2 returns provider resolution error without replacing state", %{
    pid: pid,
    config: config
  } do
    bad_config = %{config | provider: "no-such-provider"}

    before_state = :sys.get_state(pid)

    assert {:error, :missing_provider_atom} = State.refresh_config(pid, bad_config)

    after_state = :sys.get_state(pid)
    assert after_state.config == before_state.config
    assert after_state.chat == before_state.chat
    assert after_state.ingress_status == before_state.ingress_status
  end

  test "monitor_listeners/2 ignores non-pid values", %{pid: pid} do
    invalid_listeners = [:not_a_pid, "listener", nil]

    before_state = :sys.get_state(pid)

    State.monitor_listeners(pid, invalid_listeners)
    :sys.get_state(pid)

    after_state = :sys.get_state(pid)
    assert after_state.listener_monitors == before_state.listener_monitors
  end

  test "handle_info/2 ignores DOWN messages for unknown monitor refs", %{pid: pid} do
    unknown_ref = make_ref()

    before_state = :sys.get_state(pid)

    send(pid, {:DOWN, unknown_ref, :process, self(), :normal})

    after_state = :sys.get_state(pid)

    assert after_state.listener_monitors == before_state.listener_monitors
    assert after_state.ingress_status == before_state.ingress_status
    assert after_state.chat == before_state.chat
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

  test "add_reaction/6 delegates through bridge outbound API", %{pid: pid} do
    Process.register(self(), :state_test_observer)

    assert :ok =
             State.add_reaction(pid, "mattermost", "chan-1", "msg-1", "+1", %{
               url: "https://mm.example.com",
               token: "tok"
             })

    assert_received {:state_add_reaction, "chan-1", "msg-1", "+1", opts}
    assert opts[:url] == "https://mm.example.com"
    assert opts[:token] == "tok"

    Process.unregister(:state_test_observer)
  end

  test "remove_reaction/6 delegates through bridge outbound API", %{pid: pid} do
    Process.register(self(), :state_test_observer)

    assert :ok =
             State.remove_reaction(pid, "mattermost", "chan-1", "msg-1", "+1", %{
               url: "https://mm.example.com",
               token: "tok"
             })

    assert_received {:state_remove_reaction, "chan-1", "msg-1", "+1", opts}
    assert opts[:url] == "https://mm.example.com"
    assert opts[:token] == "tok"

    Process.unregister(:state_test_observer)
  end

  describe "process_listener_payload/4 reaction ingress" do
    # Starts a dedicated state process *after* installing StubBridge: handlers are
    # registered once, in `build_chat/3` during `init/1`, so swapping the bridge
    # module afterwards would leave the already-built chat wired to the real one.
    setup %{config: config} do
      previous = Application.get_env(:zaq, JidoChatBridge, [])

      Application.put_env(
        :zaq,
        JidoChatBridge,
        Keyword.put(previous, :bridge_module, StubBridge)
      )

      Process.register(self(), :state_test_observer)

      {:ok, pid} =
        State.start_link(
          bridge_id: "mattermost_reaction_1",
          config: config,
          provider: :mattermost,
          handler_opts: %{}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
        Application.put_env(:zaq, JidoChatBridge, previous)
      end)

      {:ok, pid: pid}
    end

    test "hands a normalized reaction event to the bridge", %{pid: pid, config: config} do
      assert :ok =
               State.process_listener_payload(pid, config, reaction_envelope(),
                 transport: :websocket
               )

      assert_received {:state_handle_reaction, ^config, %ReactionEvent{} = reaction}
      assert reaction.emoji == "thumbsup"
      assert reaction.added
      assert reaction.message_id == "msg-1"
      assert reaction.adapter_name == :mattermost
      assert reaction.user.user_id == "user-1"
      assert %Jido.Chat.Thread{external_room_id: "chan-1"} = reaction.thread
    end

    test "never routes a reaction through transform_incoming", %{pid: pid, config: config} do
      assert :ok =
               State.process_listener_payload(pid, config, reaction_envelope(),
                 transport: :websocket
               )

      refute_received {:state_transform_incoming, _payload}
    end

    test "leaves ingress status untouched for reactions", %{pid: pid, config: config} do
      before_status = State.ingress_status(pid)

      assert :ok =
               State.process_listener_payload(pid, config, reaction_envelope(),
                 transport: :websocket
               )

      assert State.ingress_status(pid) == before_status
    end

    test "routes a reaction with no usable emoji without crashing", %{
      pid: pid,
      config: config
    } do
      payload = reaction_envelope(%{emoji: nil})

      assert :ok = State.process_listener_payload(pid, config, payload, transport: :websocket)
      assert Process.alive?(pid)

      # The envelope still routes — dropping an unusable emoji is now
      # `ReactionMapper.to_rating/2`'s call on the channel side, not an ingress
      # concern. `mattermost_reaction_ingress_test.exs` asserts the dispatch-level
      # consequence: an unmapped emoji reaches the engine as nothing at all.
      assert_received {:state_handle_reaction, ^config, %ReactionEvent{emoji: nil}}
    end

    test "routes an unknown envelope event type without crashing", %{pid: pid, config: config} do
      payload = %{reaction_envelope() | event_type: :modal_close}

      assert :ok = State.process_listener_payload(pid, config, payload, transport: :websocket)
      refute_received {:state_handle_reaction, _config, _reaction}
      assert Process.alive?(pid)
    end

    test "leaves ingress status untouched for unroutable envelopes", %{pid: pid, config: config} do
      before_status = State.ingress_status(pid)
      payload = %{reaction_envelope() | event_type: :modal_close}

      assert :ok = State.process_listener_payload(pid, config, payload, transport: :websocket)
      assert State.ingress_status(pid) == before_status
    end

    test "still processes message payloads through the adapter", %{pid: pid, config: config} do
      assert :ok =
               State.process_listener_payload(pid, config, %{"event" => "posted"},
                 transport: :websocket
               )

      assert %{status: :ok} = State.ingress_status(pid)
      refute_received {:state_handle_reaction, _config, _reaction}
    end
  end

  test "send_reply/3 returns error for unsupported provider", %{pid: pid} do
    outgoing = %Outgoing{
      body: "hello",
      channel_id: "chan-1",
      thread_id: nil,
      provider: :no_such_provider,
      metadata: %{}
    }

    assert {:error, {:unsupported_provider, :no_such_provider}} =
             State.send_reply(pid, outgoing, %{url: "https://mm.example.com", token: "tok"})
  end

  test "process_webhook_request/3 returns error when chat module returns invalid chat", %{
    pid: pid,
    config: config
  } do
    previous_chat_module = Application.get_env(:zaq, :chat_bridge_chat_module)

    Application.put_env(:zaq, :chat_bridge_chat_module, StubChatModuleInvalidWebhookState)

    on_exit(fn ->
      if previous_chat_module do
        Application.put_env(:zaq, :chat_bridge_chat_module, previous_chat_module)
      else
        Application.delete_env(:zaq, :chat_bridge_chat_module)
      end
    end)

    payload = %{
      "method" => "POST",
      "path" => "/channels/webhook/conversation/mattermost",
      "headers" => %{"x-test" => "1"},
      "payload" => %{"event" => "message"}
    }

    before_state = :sys.get_state(pid)

    assert {:error,
            {:unexpected_webhook_result,
             {:ok, :invalid_chat_state, :noop, %{body: "ok", headers: %{}, status: 200}}}} =
             State.process_webhook_request(pid, config, payload)

    after_state = :sys.get_state(pid)
    assert after_state.chat == before_state.chat
  end

  defp assert_eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 500) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if System.monotonic_time(:millisecond) >= deadline do
        reraise error, __STACKTRACE__
      else
        Process.sleep(10)
        assert_eventually(fun, deadline)
      end
  end
end
