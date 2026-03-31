defmodule Zaq.Channels.JidoChatBridgeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Author
  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  # ── Stub modules ──────────────────────────────────────────────────────

  defmodule StubHooks do
    def dispatch_before(:reply_received, post, _ctx) do
      send(self(), {:reply_received, post})
      :ok
    end

    def dispatch_before(_event, _payload, _ctx), do: :ok
  end

  defmodule StubPipeline do
    def run(%Incoming{} = incoming, opts) do
      send(self(), {:pipeline_run, incoming.content, opts})

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
      send(self(), {:router_deliver, outgoing})
      :ok
    end
  end

  defmodule FailingRouter do
    def deliver(_outgoing), do: {:error, :timeout}
  end

  defmodule StubConversations do
    def persist_from_incoming(_msg, _result), do: :ok
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
end
