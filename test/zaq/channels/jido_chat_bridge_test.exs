defmodule Zaq.Channels.JidoChatBridgeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Author
  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Channels.Supervisor
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  # ── Stub modules ──────────────────────────────────────────────────────

  defmodule StubHooks do
    def dispatch_before(:reply_received, post, _ctx) do
      (Process.whereis(:bridge_test_observer) || self())
      |> then(&send(&1, {:reply_received, post}))

      :ok
    end

    def dispatch_before(_event, _payload, _ctx), do: :ok
  end

  defmodule StubPipeline do
    def run(%Incoming{} = incoming, opts) do
      (Process.whereis(:bridge_test_observer) || self())
      |> then(&send(&1, {:pipeline_run, incoming.content, opts}))

      %Outgoing{
        body: "stub answer",
        channel_id: incoming.channel_id,
        provider: incoming.provider,
        metadata: %{
          answer: "stub answer",
          confidence_score: 0.9,
          latency_ms: 42,
          prompt_tokens: 10,
          completion_tokens: 20,
          total_tokens: 30,
          error: false
        }
      }
    end
  end

  defmodule StubRouter do
    def deliver(%Outgoing{} = outgoing) do
      (Process.whereis(:bridge_test_observer) || self())
      |> then(&send(&1, {:router_deliver, outgoing}))

      :ok
    end
  end

  defmodule FailingRouter do
    def deliver(_outgoing), do: {:error, :timeout}
  end

  defmodule StubConversations do
    def persist_from_incoming(_msg, _result), do: :ok
  end

  defmodule StubAdapterOutbound do
    def start_typing(channel_id, opts) do
      send(self(), {:start_typing, channel_id, opts})
      :ok
    end

    def add_reaction(channel_id, message_id, emoji, opts) do
      send(self(), {:add_reaction, channel_id, message_id, emoji, opts})
      {:ok, %{}}
    end

    def remove_reaction(channel_id, message_id, emoji, opts) do
      send(self(), {:remove_reaction, channel_id, message_id, emoji, opts})
      :ok
    end
  end

  defmodule StubAdapterNoOutboundFns do
    def listener_child_specs(_bridge_id, _opts), do: {:ok, []}
  end

  defmodule StubAdapterListenerOpts do
    def listener_child_specs(_bridge_id, opts) do
      send(self(), {:listener_child_specs_opts, opts})
      {:ok, []}
    end
  end

  defmodule StubAdapterTestConnection do
    def send_message(channel_id, message, opts) do
      send(self(), {:adapter_send_message, channel_id, message, opts})
      {:ok, :sent}
    end
  end

  defmodule StubListenerAdapter do
    def transform_incoming(%{"type" => "message", "text" => text}) do
      {:ok,
       %ChatIncoming{
         text: text,
         external_room_id: "chan-1",
         external_thread_id: nil,
         external_message_id: "msg-1",
         author: %Author{user_id: "u1", user_name: "alice"},
         was_mentioned: true,
         metadata: %{},
         channel_meta: %{adapter_name: :mattermost}
       }}
    end

    def transform_incoming(%{"type" => "thread_reply", "text" => text, "root_id" => root_id}) do
      {:ok,
       %ChatIncoming{
         text: text,
         external_room_id: "chan-1",
         external_thread_id: root_id,
         external_message_id: "reply-1",
         author: %Author{user_id: "u1", user_name: "alice"},
         was_mentioned: false,
         metadata: %{},
         channel_meta: %{adapter_name: :mattermost}
       }}
    end

    def transform_incoming(%{"type" => "reaction"}), do: {:error, :unsupported_event}
  end

  defmodule StubAccounts do
    def get_user_by_username("alice"), do: %{id: "u1", username: "alice"}
    def get_user_by_username(_), do: nil
  end

  defmodule StubPermissions do
    def list_accessible_role_ids(%{id: "u1"}), do: ["role1", "role2"]
  end

  setup do
    Application.put_env(:zaq, :pipeline_hooks_module, StubHooks)
    Application.put_env(:zaq, :chat_bridge_pipeline_module, StubPipeline)
    Application.put_env(:zaq, :chat_bridge_router_module, StubRouter)
    Application.put_env(:zaq, :chat_bridge_conversations_module, StubConversations)
    Application.put_env(:zaq, :chat_bridge_accounts_module, StubAccounts)
    Application.put_env(:zaq, :chat_bridge_permissions_module, StubPermissions)

    on_exit(fn ->
      Application.delete_env(:zaq, :pipeline_hooks_module)
      Application.delete_env(:zaq, :chat_bridge_pipeline_module)
      Application.delete_env(:zaq, :chat_bridge_router_module)
      Application.delete_env(:zaq, :chat_bridge_conversations_module)
      Application.delete_env(:zaq, :chat_bridge_accounts_module)
      Application.delete_env(:zaq, :chat_bridge_permissions_module)
    end)

    :ok
  end

  # ── to_internal/2 ─────────────────────────────────────────────────────

  describe "to_internal/2" do
    test "maps all fields from a full Chat.Incoming" do
      incoming = %ChatIncoming{
        text: "hello",
        external_room_id: "room1",
        external_thread_id: "thread1",
        external_message_id: "msg1",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{raw: "data"}
      }

      msg = JidoChatBridge.to_internal(incoming, :mattermost)

      assert msg.content == "hello"
      assert msg.channel_id == "room1"
      assert msg.thread_id == "thread1"
      assert msg.message_id == "msg1"
      assert msg.author_id == "u1"
      assert msg.author_name == "alice"
      assert msg.provider == :mattermost
      assert msg.metadata == %{raw: "data"}
    end

    test "sets provider from argument" do
      incoming = %ChatIncoming{
        text: "hi",
        external_room_id: "room1",
        external_thread_id: nil,
        external_message_id: nil,
        author: nil,
        metadata: %{}
      }

      msg = JidoChatBridge.to_internal(incoming, :slack)
      assert msg.provider == :slack
    end

    test "maps nil author to nil author fields" do
      incoming = %ChatIncoming{
        text: "hi",
        external_room_id: "room2",
        external_thread_id: nil,
        external_message_id: nil,
        author: nil,
        metadata: %{}
      }

      msg = JidoChatBridge.to_internal(incoming, :mattermost)

      assert is_nil(msg.author_id)
      assert is_nil(msg.author_name)
    end

    test "normalizes nil metadata to empty map" do
      incoming = %ChatIncoming{
        text: "hi",
        external_room_id: "room3",
        external_thread_id: nil,
        external_message_id: nil,
        author: nil,
        metadata: nil
      }

      msg = JidoChatBridge.to_internal(incoming, :mattermost)
      assert msg.metadata == %{}
    end
  end

  # ── resolve_roles/1 ───────────────────────────────────────────────────

  describe "resolve_roles/1" do
    test "returns {:ok, nil} when author_name is nil" do
      assert {:ok, nil} == JidoChatBridge.resolve_roles(%{author_name: nil})
    end

    test "returns {:ok, role_ids} for known user" do
      assert {:ok, ["role1", "role2"]} == JidoChatBridge.resolve_roles(%{author_name: "alice"})
    end

    test "returns {:ok, nil} for unknown user" do
      assert {:ok, nil} == JidoChatBridge.resolve_roles(%{author_name: "unknown"})
    end
  end

  # ── handle_from_listener/3 ────────────────────────────────────────────

  describe "handle_from_listener/3" do
    @config %{url: "https://mm.example.com", token: "tok", bot_name: "zaq", bot_user_id: "bot-1"}

    test "thread reply dispatches :reply_received hook and returns :ok" do
      incoming = %ChatIncoming{
        text: "The answer is 42",
        external_room_id: "chan-1",
        external_thread_id: "root-post-id",
        external_message_id: "reply-post-id",
        author: %Author{user_id: "sme-1", user_name: "alice"},
        metadata: %{}
      }

      assert :ok = JidoChatBridge.handle_from_listener(@config, incoming, [])

      assert_received {:reply_received,
                       %{root_id: "root-post-id", user_id: "sme-1", message: "The answer is 42"}}
    end

    test "non-reply message runs the pipeline and delivers via Router" do
      incoming = %ChatIncoming{
        text: "What is the capital of France?",
        external_room_id: "chan-1",
        external_thread_id: nil,
        external_message_id: "msg-1",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{}
      }

      JidoChatBridge.handle_from_listener(@config, incoming, [])
      assert_received {:pipeline_run, "What is the capital of France?", _opts}
      assert_received {:router_deliver, %Outgoing{body: "stub answer"}}
    end

    test "non-reply message with empty external_thread_id runs the pipeline" do
      incoming = %ChatIncoming{
        text: "Another question",
        external_room_id: "chan-1",
        external_thread_id: "",
        external_message_id: "msg-2",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{}
      }

      JidoChatBridge.handle_from_listener(@config, incoming, [])
      assert_received {:pipeline_run, "Another question", _opts}
    end

    test "thread reply does NOT run the pipeline" do
      incoming = %ChatIncoming{
        text: "SME reply",
        external_room_id: "chan-1",
        external_thread_id: "root-post-id",
        external_message_id: "reply-1",
        author: %Author{user_id: "sme-1", user_name: "alice"},
        metadata: %{}
      }

      JidoChatBridge.handle_from_listener(@config, incoming, [])

      refute_received {:pipeline_run, _, _}
    end

    test "logs and returns error when Router delivery fails" do
      Application.put_env(:zaq, :chat_bridge_router_module, FailingRouter)

      on_exit(fn ->
        Application.put_env(:zaq, :chat_bridge_router_module, StubRouter)
      end)

      incoming = %ChatIncoming{
        text: "question",
        external_room_id: "room1",
        external_thread_id: nil,
        external_message_id: "msg1",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{}
      }

      assert {:error, :timeout} = JidoChatBridge.handle_from_listener(@config, incoming, [])
    end
  end

  describe "outbound event APIs" do
    setup do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubAdapterOutbound,
          ingress_mode: :websocket
        }
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      :ok
    end

    test "send_typing/3 delegates to adapter" do
      assert :ok =
               JidoChatBridge.send_typing("mattermost", "chan-1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert_received {:start_typing, "chan-1", opts}
      assert opts[:url] == "https://mm.example.com"
      assert opts[:token] == "tok"
    end

    test "add_reaction/5 delegates to adapter" do
      assert :ok =
               JidoChatBridge.add_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert_received {:add_reaction, "chan-1", "msg-1", "+1", opts}
      assert opts[:url] == "https://mm.example.com"
      assert opts[:token] == "tok"
    end

    test "remove_reaction/5 includes optional user_id" do
      assert :ok =
               JidoChatBridge.remove_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok",
                 user_id: "u-1"
               })

      assert_received {:remove_reaction, "chan-1", "msg-1", "+1", opts}
      assert opts[:url] == "https://mm.example.com"
      assert opts[:token] == "tok"
      assert opts[:user_id] == "u-1"
    end

    test "send_typing/3 returns unsupported for unknown provider" do
      assert {:error, {:unsupported_provider, "slack"}} =
               JidoChatBridge.send_typing("slack", "chan-1", %{
                 url: "https://slack.example.com",
                 token: "tok"
               })
    end

    test "send_typing/3 returns missing_connection_details without url/token" do
      assert {:error, :missing_connection_details} =
               JidoChatBridge.send_typing("mattermost", "chan-1", %{})
    end

    test "add_reaction/5 returns missing_connection_details without url/token" do
      assert {:error, :missing_connection_details} =
               JidoChatBridge.add_reaction("mattermost", "chan-1", "msg-1", "+1", %{})
    end

    test "remove_reaction/5 returns missing_connection_details without url/token" do
      assert {:error, :missing_connection_details} =
               JidoChatBridge.remove_reaction("mattermost", "chan-1", "msg-1", "+1", %{})
    end

    test "send_typing/3 returns unsupported when adapter has no callback" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterNoOutboundFns}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, :unsupported} =
               JidoChatBridge.send_typing("mattermost", "chan-1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end

    test "start_runtime/1 and stop_runtime/1 manage config runtime" do
      previous = Application.get_env(:zaq, :channels, %{})

      on_exit(fn ->
        Application.put_env(:zaq, :channels, previous)
      end)

      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubAdapterOutbound,
          ingress_mode: :webhook
        }
      })

      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      }

      assert :ok = JidoChatBridge.start_runtime(config)
      assert :ok = JidoChatBridge.stop_runtime(config)
    end

    test "runtime_specs/3 includes ingress defaults and custom ingress settings" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubAdapterListenerOpts,
          ingress_mode: :gateway
        }
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{
          "jido_chat" => %{
            "bot_name" => "zaq",
            "bot_user_id" => "bot-1",
            "ingress" => %{"source" => "nostrum"}
          }
        }
      }

      {_state_spec, listener_specs} =
        JidoChatBridge.runtime_specs(config, "bridge_ingress_test", channel_ids: ["chan-1"])

      assert listener_specs == []
      assert_received {:listener_child_specs_opts, listener_opts}
      assert listener_opts[:ingress] == %{"mode" => "gateway", "source" => "nostrum"}
      assert listener_opts[:sink_opts][:transport] == :gateway
    end
  end

  describe "subscribe_thread_reply/3 and unsubscribe_thread_reply/3" do
    setup do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubListenerAdapter,
          ingress_mode: :webhook
        }
      })

      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      }

      on_exit(fn ->
        Application.put_env(:zaq, :channels, previous)
      end)

      {:ok, config: config}
    end

    test "subscribe_thread_reply/3 starts dedicated thread runtime and subscribes", %{
      config: config
    } do
      assert :ok = JidoChatBridge.subscribe_thread_reply(config, "chan-1", "thread-1")

      bridge_id = "chan-1_thread-1"
      assert {:ok, state_pid} = Supervisor.lookup_state_pid(bridge_id)

      state = :sys.get_state(state_pid)
      key = JidoChatBridge.thread_key(:mattermost, "chan-1", "thread-1")
      assert MapSet.member?(state.chat.subscriptions, key)

      assert :ok = Supervisor.stop_bridge_runtime(config, bridge_id)
    end

    test "unsubscribe_thread_reply/3 stops thread runtime", %{config: config} do
      assert :ok = JidoChatBridge.subscribe_thread_reply(config, "chan-1", "thread-2")

      bridge_id = "chan-1_thread-2"
      assert {:ok, _} = Supervisor.lookup_state_pid(bridge_id)

      assert :ok = JidoChatBridge.unsubscribe_thread_reply(config, "chan-1", "thread-2")
      assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
    end

    test "unsubscribe_thread_reply/3 returns not_running when not subscribed", %{config: config} do
      assert {:error, :not_running} =
               JidoChatBridge.unsubscribe_thread_reply(config, "chan-1", "no-such-thread")
    end
  end

  describe "send_reply/2 and do_send_reply/2" do
    setup do
      previous = Application.get_env(:zaq, :channels, %{})
      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
      :ok
    end

    test "send_reply/2 returns error when connection details are missing" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        thread_id: nil,
        provider: :mattermost,
        metadata: %{}
      }

      assert {:error, :missing_connection_details} = JidoChatBridge.send_reply(outgoing, %{})
    end

    test "do_send_reply/2 returns unsupported_provider for unknown provider" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        thread_id: nil,
        provider: :no_such_provider,
        metadata: %{}
      }

      assert {:error, {:unsupported_provider, :no_such_provider}} =
               JidoChatBridge.do_send_reply(outgoing, %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end
  end

  describe "adapter and connectivity" do
    test "adapter_for/1 returns unsupported_provider for unknown provider" do
      assert {:error, :unsupported_provider} = JidoChatBridge.adapter_for("does-not-exist")
    end

    test "test_connection/2 delegates to adapter send_message" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterTestConnection}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{provider: "mattermost", url: "https://mm.example.com", token: "tok"}

      assert {:ok, :sent} = JidoChatBridge.test_connection(config, "chan-1")
      assert_received {:adapter_send_message, "chan-1", _message, opts}
      assert opts[:url] == "https://mm.example.com"
      assert opts[:token] == "tok"
    end
  end

  describe "from_listener/3 raw payload path" do
    setup do
      Process.register(self(), :bridge_test_observer)

      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubListenerAdapter,
          ingress_mode: :webhook
        }
      })

      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      }

      bridge_id = "mattermost_from_listener_#{System.unique_integer([:positive])}"

      {state_spec, listener_specs} = JidoChatBridge.runtime_specs(config, bridge_id, [])
      assert {:ok, _runtime} = Supervisor.start_runtime(bridge_id, state_spec, listener_specs)

      on_exit(fn ->
        _ = Supervisor.stop_bridge_runtime(config, bridge_id)
        Application.put_env(:zaq, :channels, previous)
        if Process.whereis(:bridge_test_observer), do: Process.unregister(:bridge_test_observer)
      end)

      {:ok, config: config, bridge_id: bridge_id}
    end

    test "new message payload reaches pipeline", %{config: config, bridge_id: bridge_id} do
      assert :ok =
               JidoChatBridge.from_listener(config, %{"type" => "message", "text" => "hello raw"},
                 bridge_id: bridge_id,
                 transport: :webhook
               )

      assert_received {:pipeline_run, "hello raw", _opts}
    end

    test "thread reply payload triggers reply hook (subscribed thread)", %{
      config: config,
      bridge_id: bridge_id
    } do
      assert {:ok, state_pid} = Supervisor.lookup_state_pid(bridge_id)
      assert :ok = State.subscribe_thread(state_pid, :mattermost, "chan-1", "root-1")

      assert :ok =
               JidoChatBridge.from_listener(
                 config,
                 %{"type" => "thread_reply", "text" => "reply raw", "root_id" => "root-1"},
                 bridge_id: bridge_id,
                 transport: :webhook
               )

      assert_received {:reply_received, %{root_id: "root-1", message: "reply raw"}}
      refute_received {:pipeline_run, _, _}
    end

    test "reaction payload returns adapter unsupported error", %{
      config: config,
      bridge_id: bridge_id
    } do
      assert {:error, :unsupported_event} =
               JidoChatBridge.from_listener(config, %{"type" => "reaction"},
                 bridge_id: bridge_id,
                 transport: :webhook
               )
    end
  end
end
