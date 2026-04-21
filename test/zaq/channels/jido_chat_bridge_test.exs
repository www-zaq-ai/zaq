defmodule Zaq.Channels.JidoChatBridgeTest do
  use Zaq.DataCase, async: false
  import ExUnit.CaptureLog

  alias Jido.Chat
  alias Jido.Chat.Author
  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Channels.Supervisor
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  # ── Stub modules ──────────────────────────────────────────────────────

  defmodule StubHooks do
    def dispatch_sync(:reply_received, post, _ctx) do
      (Process.whereis(:bridge_test_observer) || self())
      |> then(&send(&1, {:reply_received, post}))

      :ok
    end

    def dispatch_sync(_event, _payload, _ctx), do: :ok
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

  defmodule StubNodeRouter do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      response =
        case event.opts[:action] do
          :run_pipeline ->
            %Outgoing{
              body: "stub from node router",
              channel_id: event.request.channel_id,
              provider: event.request.provider,
              metadata: %{answer: "stub"}
            }

          :deliver_outgoing ->
            :ok

          :persist_from_incoming ->
            :ok

          _ ->
            {:error, :unsupported}
        end

      %{event | response: response}
    end
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

  defmodule StubAdapterOutboundError do
    def start_typing(_channel_id, _opts), do: {:error, :typing_failed}
    def add_reaction(_channel_id, _message_id, _emoji, _opts), do: {:error, :reaction_failed}
    def remove_reaction(_channel_id, _message_id, _emoji, _opts), do: {:error, :reaction_failed}
  end

  defmodule StubAdapterOutboundUnexpected do
    def start_typing(_channel_id, _opts), do: :unexpected
    def add_reaction(_channel_id, _message_id, _emoji, _opts), do: :unexpected
    def remove_reaction(_channel_id, _message_id, _emoji, _opts), do: :unexpected
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

  defmodule StubAdapterGetUser do
    def get_user(author_id, opts) do
      send(self(), {:adapter_get_user, author_id, opts})

      {:ok,
       %{
         email: "user@example.com",
         display_name: "Display Name",
         username: "profile_user",
         phone: "+15550001"
       }}
    end
  end

  defmodule StubAdapterThreadPost do
    def send_message(_channel_id, _text, _opts) do
      {:ok, %{external_message_id: "post-123"}}
    end
  end

  defmodule FailingThreadPostAdapter do
    def send_message(_channel_id, _text, _opts), do: {:error, :send_failed}
  end

  defmodule StubOnReplyWorker do
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule InvalidOnReplyWorker do
    def new(_args), do: Oban.Job.new(%{}, queue: :default)
  end

  defmodule StubAdapterListenerError do
    def listener_child_specs(_bridge_id, _opts), do: {:error, :listener_boot_failed}
  end

  defmodule StubAdapterOpenDmChannel do
    def open_dm_channel(bot_user_id, author_id, opts) do
      send(self(), {:open_dm_channel, bot_user_id, author_id, opts})
      {:ok, %{"id" => "DM_CH_BRIDGE_1"}}
    end
  end

  defmodule StubAdapterOpenDmChannelNoId do
    def open_dm_channel(_bot_user_id, _author_id, _opts) do
      {:ok, %{}}
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
    Application.delete_env(:zaq, :chat_bridge_node_router_module)

    on_exit(fn ->
      Application.delete_env(:zaq, :pipeline_hooks_module)
      Application.delete_env(:zaq, :chat_bridge_pipeline_module)
      Application.delete_env(:zaq, :chat_bridge_router_module)
      Application.delete_env(:zaq, :chat_bridge_conversations_module)
      Application.delete_env(:zaq, :chat_bridge_accounts_module)
      Application.delete_env(:zaq, :chat_bridge_permissions_module)
      Application.delete_env(:zaq, :chat_bridge_node_router_module)
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

      log =
        capture_log(fn ->
          assert {:error, :timeout} = JidoChatBridge.handle_from_listener(@config, incoming, [])
        end)

      assert log =~ "Failed to process message"
    end

    test "uses NodeRouter dispatch path when bridge modules are defaults" do
      Application.put_env(:zaq, :chat_bridge_pipeline_module, Zaq.Agent.Pipeline)
      Application.put_env(:zaq, :chat_bridge_router_module, Zaq.Channels.Router)
      Application.put_env(:zaq, :chat_bridge_conversations_module, Zaq.Engine.Conversations)
      Application.put_env(:zaq, :chat_bridge_node_router_module, StubNodeRouter)

      incoming = %ChatIncoming{
        text: "node-router",
        external_room_id: "room1",
        external_thread_id: nil,
        external_message_id: "msg1",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{}
      }

      assert :ok = JidoChatBridge.handle_from_listener(@config, incoming, [])
    end

    test "uses incoming channel adapter when present, even if unsupported" do
      incoming = %ChatIncoming{
        text: "question",
        external_room_id: "room1",
        external_thread_id: nil,
        external_message_id: "msg1",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{},
        channel_meta: %{adapter_name: :no_such_adapter, is_dm: false}
      }

      assert :ok = JidoChatBridge.handle_from_listener(@config, incoming, [])
      assert_received {:pipeline_run, "question", _opts}
    end

    test "ignores self-authored messages" do
      incoming = %ChatIncoming{
        text: "bot echo",
        external_room_id: "room1",
        external_thread_id: nil,
        external_message_id: "msg1",
        author: %Author{user_id: "bot-1", user_name: "zaq", is_me: true},
        metadata: %{},
        channel_meta: %{adapter_name: :mattermost, is_dm: false}
      }

      assert :ok = JidoChatBridge.handle_from_listener(@config, incoming, [])
      refute_received {:pipeline_run, _, _}
      refute_received {:router_deliver, _}
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

    test "remove_reaction/5 omits user_id when absent" do
      assert :ok =
               JidoChatBridge.remove_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert_received {:remove_reaction, "chan-1", "msg-1", "+1", opts}
      refute Keyword.has_key?(opts, :user_id)
    end

    test "provider map overloads delegate to string/atom provider API" do
      provider = %{provider: "mattermost"}

      assert :ok =
               JidoChatBridge.send_typing(provider, "chan-1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert :ok =
               JidoChatBridge.add_reaction(provider, "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert :ok =
               JidoChatBridge.remove_reaction(provider, "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
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

    test "add_reaction/5 returns unsupported when adapter has no callback" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterNoOutboundFns}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, :unsupported} =
               JidoChatBridge.add_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end

    test "remove_reaction/5 returns unsupported when adapter has no callback" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterNoOutboundFns}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, :unsupported} =
               JidoChatBridge.remove_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end

    test "outbound APIs preserve adapter errors" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterOutboundError}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, :typing_failed} =
               JidoChatBridge.send_typing("mattermost", "chan-1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert {:error, :reaction_failed} =
               JidoChatBridge.add_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert {:error, :reaction_failed} =
               JidoChatBridge.remove_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end

    test "outbound APIs normalize unexpected adapter responses" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterOutboundUnexpected}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, {:unexpected_response, :unexpected}} =
               JidoChatBridge.send_typing("mattermost", "chan-1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert {:error, {:unexpected_response, :unexpected}} =
               JidoChatBridge.add_reaction("mattermost", "chan-1", "msg-1", "+1", %{
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert {:error, {:unexpected_response, :unexpected}} =
               JidoChatBridge.remove_reaction("mattermost", "chan-1", "msg-1", "+1", %{
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

    test "runtime_specs/3 falls back to default ingress when configured ingress is not a map" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubAdapterListenerOpts,
          ingress_mode: :polling
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
            "ingress" => "invalid"
          }
        }
      }

      {_state_spec, _listener_specs} =
        JidoChatBridge.runtime_specs(config, "bridge_ingress_fallback_test",
          channel_ids: ["chan-1"]
        )

      assert_received {:listener_child_specs_opts, listener_opts}
      assert listener_opts[:ingress] == %{"mode" => "polling"}
      assert listener_opts[:sink_opts][:transport] == :polling
    end

    test "runtime_specs/3 returns empty listeners when adapter listener specs fail" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterListenerError}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      }

      {_state_spec, listener_specs} =
        JidoChatBridge.runtime_specs(config, "bridge_listener_error_test", [])

      assert listener_specs == []
    end

    test "runtime_specs/3 uses default channel_ids (:all) when none are active" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubAdapterListenerOpts,
          ingress_mode: :websocket
        }
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      }

      {_state_spec, _listener_specs} =
        JidoChatBridge.runtime_specs(config, "bridge_default_channels")

      assert_received {:listener_child_specs_opts, listener_opts}
      assert listener_opts[:channel_ids] == :all
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

      log =
        capture_log(fn ->
          assert {:error, :missing_connection_details} = JidoChatBridge.send_reply(outgoing, %{})
        end)

      assert log =~ "send_reply called without connection details"
    end

    test "send_reply/2 delegates to do_send_reply/2 with connection details" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterThreadPost}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        thread_id: nil,
        provider: :mattermost,
        metadata: %{}
      }

      assert :ok =
               JidoChatBridge.send_reply(outgoing, %{url: "https://mm.example.com", token: "tok"})
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

    test "do_send_reply/2 dispatches on_reply metadata successfully" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterThreadPost}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        thread_id: nil,
        provider: :mattermost,
        metadata: %{
          "on_reply" => %{
            "module" => Atom.to_string(StubOnReplyWorker),
            "args" => %{"conversation_id" => "conv-1"}
          }
        }
      }

      assert :ok =
               JidoChatBridge.do_send_reply(outgoing, %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end

    test "do_send_reply/2 logs warning path when on_reply insert returns error" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterThreadPost}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        thread_id: nil,
        provider: :mattermost,
        metadata: %{
          "on_reply" => %{
            "module" => Atom.to_string(InvalidOnReplyWorker),
            "args" => %{"conversation_id" => "conv-1"}
          }
        }
      }

      log =
        capture_log(fn ->
          assert :ok =
                   JidoChatBridge.do_send_reply(outgoing, %{
                     url: "https://mm.example.com",
                     token: "tok"
                   })
        end)

      assert log =~ "on_reply dispatch failed"
    end

    test "do_send_reply/2 rescue path for invalid on_reply module" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterThreadPost}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        thread_id: nil,
        provider: :mattermost,
        metadata: %{
          "on_reply" => %{
            "module" => "Elixir.Zaq.NonExistingWorker",
            "args" => %{"conversation_id" => "conv-1"}
          }
        }
      }

      log =
        capture_log(fn ->
          assert :ok =
                   JidoChatBridge.do_send_reply(outgoing, %{
                     url: "https://mm.example.com",
                     token: "tok"
                   })
        end)

      assert log =~ "on_reply dispatch failed"
    end

    test "do_send_reply/2 returns adapter post errors" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: FailingThreadPostAdapter}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        thread_id: "thread-9",
        provider: :mattermost,
        metadata: %{}
      }

      assert {:error, :send_failed} =
               JidoChatBridge.do_send_reply(outgoing, %{
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end
  end

  describe "adapter and connectivity" do
    test "adapter_for/1 returns adapter for atom and binary providers" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterOutbound}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, StubAdapterOutbound} = JidoChatBridge.adapter_for(:mattermost)
      assert {:ok, StubAdapterOutbound} = JidoChatBridge.adapter_for("mattermost")
    end

    test "adapter_for/1 returns unsupported_provider for unknown provider" do
      assert {:error, :unsupported_provider} = JidoChatBridge.adapter_for("does-not-exist")
    end

    test "test_connection/2 returns unsupported_provider for unknown provider" do
      config = %{provider: "does-not-exist", url: "https://mm.example.com", token: "tok"}
      assert {:error, :unsupported_provider} = JidoChatBridge.test_connection(config, "chan-1")
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

    test "from_listener/3 can auto-start runtime via default bridge id", %{config: config} do
      bridge_id = "#{config.provider}_#{config.id}"
      assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)

      assert :ok =
               JidoChatBridge.from_listener(
                 config,
                 %{"type" => "message", "text" => "auto-start"},
                 []
               )

      assert {:ok, _runtime} = Supervisor.lookup_runtime(bridge_id)
      assert_received {:pipeline_run, "auto-start", _opts}

      assert :ok = JidoChatBridge.stop_runtime(config)
    end
  end

  describe "register_handlers/3" do
    test "default handler opts path handles DM and configured channel pattern" do
      config = %{
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"message_patterns" => ["deploy"]}}
      }

      chat =
        Chat.new(user_name: "zaq", adapters: %{mattermost: StubListenerAdapter})
        |> JidoChatBridge.register_handlers(config)

      dm_incoming = %ChatIncoming{
        text: "hello from dm",
        external_room_id: "dm-1",
        external_thread_id: nil,
        external_message_id: "dm-msg-1",
        author: %Author{user_id: "u1", user_name: "alice", is_me: false},
        metadata: %{},
        channel_meta: %{adapter_name: :mattermost, is_dm: true}
      }

      assert {:ok, _chat, _events} =
               Chat.process_message(chat, :mattermost, "mattermost:dm-1:dm-1", dm_incoming, [])

      assert_received {:pipeline_run, "hello from dm", _opts}

      channel_incoming = %ChatIncoming{
        text: "deploy now",
        external_room_id: "chan-1",
        external_thread_id: nil,
        external_message_id: "chan-msg-1",
        author: %Author{user_id: "u1", user_name: "alice", is_me: false},
        metadata: %{},
        channel_meta: %{adapter_name: :mattermost, is_dm: false}
      }

      assert {:ok, _chat, _events} =
               Chat.process_message(
                 chat,
                 :mattermost,
                 "mattermost:chan-1:chan-1",
                 channel_incoming,
                 []
               )

      assert_received {:pipeline_run, "deploy now", _opts}
    end

    test "mention events trigger processing for non-DM messages" do
      config = %{
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{}}
      }

      chat =
        Chat.new(user_name: "zaq", adapters: %{mattermost: StubListenerAdapter})
        |> JidoChatBridge.register_handlers(config)

      mention_incoming = %ChatIncoming{
        text: "@zaq please answer",
        external_room_id: "chan-1",
        external_thread_id: nil,
        external_message_id: "chan-msg-2",
        author: %Author{user_id: "u1", user_name: "alice", is_me: false},
        was_mentioned: true,
        metadata: %{},
        channel_meta: %{adapter_name: :mattermost, is_dm: false}
      }

      assert {:ok, _chat, _events} =
               Chat.process_message(
                 chat,
                 :mattermost,
                 "mattermost:chan-1:chan-1",
                 mention_incoming,
                 []
               )

      assert_received {:pipeline_run, "@zaq please answer", _opts}
    end
  end

  describe "fetch_profile/2" do
    setup do
      previous = Application.get_env(:zaq, :channels, %{})

      on_exit(fn ->
        Application.put_env(:zaq, :channels, previous)
      end)

      :ok
    end

    test "returns mapped canonical profile when adapter supports get_user/2" do
      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterGetUser}
      })

      assert {:ok, profile} =
               JidoChatBridge.fetch_profile("author-1", %{
                 provider: "mattermost",
                 url: "https://mm.example.com",
                 token: "tok"
               })

      assert profile["email"] == "user@example.com"
      assert profile["display_name"] == "Display Name"
      assert profile["username"] == "profile_user"
      assert profile["phone"] == "+15550001"

      assert_received {:adapter_get_user, "author-1", opts}
      assert opts[:url] == "https://mm.example.com"
      assert opts[:token] == "tok"
    end

    test "returns unsupported when adapter does not implement get_user/2" do
      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterNoOutboundFns}
      })

      assert {:error, :unsupported} =
               JidoChatBridge.fetch_profile("author-1", %{
                 provider: "mattermost",
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end

    test "returns unsupported_provider tuple for unknown provider" do
      assert {:error, {:unsupported_provider, "does-not-exist"}} =
               JidoChatBridge.fetch_profile("author-1", %{
                 provider: "does-not-exist",
                 url: "https://mm.example.com",
                 token: "tok"
               })
    end

    test "returns missing_connection_details when required connection fields are absent" do
      assert {:error, :missing_connection_details} = JidoChatBridge.fetch_profile("author-1", %{})
    end
  end

  describe "open_dm_channel/2" do
    setup do
      previous = Application.get_env(:zaq, :channels, %{})
      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
      :ok
    end

    test "returns missing_connection_details when url/token/bot_user_id are absent" do
      assert {:error, :missing_connection_details} =
               JidoChatBridge.open_dm_channel("user-1", %{})
    end

    test "returns missing_connection_details when bot_user_id is not a binary" do
      assert {:error, :missing_connection_details} =
               JidoChatBridge.open_dm_channel("user-1", %{
                 url: "https://mm.example.com",
                 token: "tok",
                 bot_user_id: nil
               })
    end

    test "returns unsupported when adapter has no open_dm_channel/3" do
      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterNoOutboundFns}
      })

      assert {:error, :unsupported} =
               JidoChatBridge.open_dm_channel("user-1", %{
                 url: "https://mm.example.com",
                 token: "tok",
                 bot_user_id: "bot-1"
               })
    end

    test "returns missing_channel_id when adapter response has no id" do
      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubAdapterOpenDmChannelNoId
        }
      })

      assert {:error, :missing_channel_id} =
               JidoChatBridge.open_dm_channel("user-1", %{
                 url: "https://mm.example.com",
                 token: "tok",
                 bot_user_id: "bot-1"
               })
    end

    test "returns {:ok, channel_id} on success" do
      Application.put_env(:zaq, :channels, %{
        mattermost: %{
          bridge: Zaq.Channels.JidoChatBridge,
          adapter: StubAdapterOpenDmChannel
        }
      })

      assert {:ok, "DM_CH_BRIDGE_1"} =
               JidoChatBridge.open_dm_channel("user-1", %{
                 url: "https://mm.example.com",
                 token: "tok",
                 bot_user_id: "bot-1",
                 provider: "mattermost"
               })

      assert_received {:open_dm_channel, "bot-1", "user-1", opts}
      assert opts[:url] == "https://mm.example.com"
      assert opts[:token] == "tok"
    end

    test "returns unsupported_provider for unknown provider" do
      assert {:error, {:unsupported_provider, "no-such-provider"}} =
               JidoChatBridge.open_dm_channel("user-1", %{
                 url: "https://mm.example.com",
                 token: "tok",
                 bot_user_id: "bot-1",
                 provider: "no-such-provider"
               })
    end
  end

  describe "to_internal/2 is_dm flag" do
    test "sets is_dm: true when channel_meta.is_dm is true" do
      incoming = %ChatIncoming{
        text: "dm message",
        external_room_id: "dm-room-1",
        external_thread_id: nil,
        external_message_id: "dm-msg-1",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{},
        channel_meta: %{is_dm: true}
      }

      msg = JidoChatBridge.to_internal(incoming, :mattermost)
      assert msg.is_dm == true
    end

    test "sets is_dm: false when channel_meta is nil" do
      incoming = %ChatIncoming{
        text: "non-dm",
        external_room_id: "chan-1",
        external_thread_id: nil,
        external_message_id: "msg-1",
        author: nil,
        metadata: %{}
      }

      msg = JidoChatBridge.to_internal(incoming, :mattermost)
      assert msg.is_dm == false
    end

    test "sets is_dm: false when channel_meta.is_dm is false" do
      incoming = %ChatIncoming{
        text: "channel message",
        external_room_id: "chan-1",
        external_thread_id: nil,
        external_message_id: "msg-2",
        author: nil,
        metadata: %{},
        channel_meta: %{is_dm: false}
      }

      msg = JidoChatBridge.to_internal(incoming, :mattermost)
      assert msg.is_dm == false
    end
  end

  describe "register_handlers/3 skipped paths" do
    @config %{
      provider: "mattermost",
      url: "https://mm.example.com",
      token: "tok",
      settings: %{"jido_chat" => %{"message_patterns" => ["deploy"]}}
    }

    test "mention event that is a thread reply is silently skipped" do
      # A @mention on a thread reply hits handle_mention_event, which checks
      # thread_reply? and returns :ok without processing — pipeline must not run.
      chat =
        Chat.new(user_name: "zaq", adapters: %{mattermost: StubListenerAdapter})
        |> JidoChatBridge.register_handlers(@config)

      mention_reply = %ChatIncoming{
        text: "@zaq thread reply",
        external_room_id: "chan-1",
        external_thread_id: "root-post-id",
        external_message_id: "reply-1",
        author: %Author{user_id: "u1", user_name: "alice", is_me: false},
        was_mentioned: true,
        metadata: %{},
        channel_meta: %{adapter_name: :mattermost, is_dm: false}
      }

      assert {:ok, _chat, _events} =
               Chat.process_message(
                 chat,
                 :mattermost,
                 "mattermost:chan-1:root-post-id",
                 mention_reply,
                 []
               )

      refute_received {:pipeline_run, _, _}
    end

    test "channel pattern matching a DM message is silently skipped" do
      # handle_channel_message_event guards against DM messages; the pattern
      # handler fires but is_dm: true causes it to return without processing.
      chat =
        Chat.new(user_name: "zaq", adapters: %{mattermost: StubListenerAdapter})
        |> JidoChatBridge.register_handlers(@config)

      dm_with_pattern = %ChatIncoming{
        text: "deploy from dm",
        external_room_id: "dm-1",
        external_thread_id: nil,
        external_message_id: "dm-deploy-1",
        author: %Author{user_id: "u1", user_name: "alice", is_me: false},
        was_mentioned: false,
        metadata: %{},
        channel_meta: %{adapter_name: :mattermost, is_dm: true}
      }

      assert {:ok, _chat, _events} =
               Chat.process_message(
                 chat,
                 :mattermost,
                 "mattermost:dm-1:dm-1",
                 dm_with_pattern,
                 []
               )

      # on_new_message (all-match) fires because is_dm: true, but "deploy"
      # pattern is in handle_channel_message_event which skips DM.
      # Pipeline runs from on_new_message DM handler, not the channel pattern.
      # The key assertion is that handle_channel_message_event does NOT trigger
      # a second pipeline run.
      assert_received {:pipeline_run, "deploy from dm", _opts}
      refute_received {:pipeline_run, _, _}
    end
  end

  describe "start_runtime/1 and stop_runtime/1 error normalization" do
    test "start_runtime/1 returns forwarded errors" do
      previous = Application.get_env(:zaq, :channels, %{})

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: StubAdapterListenerError}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      }

      assert {:error, :listener_boot_failed} = JidoChatBridge.start_runtime(config)
    end

    test "stop_runtime/1 returns :ok when runtime is not running" do
      config = %{
        id: System.unique_integer([:positive]),
        provider: "mattermost",
        url: "https://mm.example.com",
        token: "tok",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
      }

      assert :ok = JidoChatBridge.stop_runtime(config)
    end
  end
end
