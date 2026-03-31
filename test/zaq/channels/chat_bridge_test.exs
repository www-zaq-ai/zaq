defmodule Zaq.Channels.ChatBridgeTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.ChatBridge
  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Jido.Chat.Author

  # ── Stub modules ──────────────────────────────────────────────────────

  defmodule StubPipeline do
    def run(content, opts) do
      send(self(), {:pipeline_run, content, opts})

      {:ok,
       %{
         answer: "stub answer",
         confidence_score: 0.9,
         latency_ms: 42,
         prompt_tokens: 10,
         completion_tokens: 20,
         total_tokens: 30
       }}
    end
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
    Application.put_env(:zaq, :chat_bridge_pipeline_module, StubPipeline)
    Application.put_env(:zaq, :chat_bridge_conversations_module, StubConversations)
    Application.put_env(:zaq, :chat_bridge_accounts_module, StubAccounts)
    Application.put_env(:zaq, :chat_bridge_permissions_module, StubPermissions)

    on_exit(fn ->
      Application.delete_env(:zaq, :chat_bridge_pipeline_module)
      Application.delete_env(:zaq, :chat_bridge_conversations_module)
      Application.delete_env(:zaq, :chat_bridge_accounts_module)
      Application.delete_env(:zaq, :chat_bridge_permissions_module)
    end)

    :ok
  end

  # ── to_internal/1 ─────────────────────────────────────────────────────

  describe "to_internal/1" do
    test "maps all fields from a full Chat.Incoming" do
      incoming = %ChatIncoming{
        text: "hello",
        external_room_id: "room1",
        external_thread_id: "thread1",
        external_message_id: "msg1",
        author: %Author{user_id: "u1", user_name: "alice"},
        metadata: %{raw: "data"}
      }

      msg = ChatBridge.to_internal(incoming)

      assert msg.content == "hello"
      assert msg.channel_id == "room1"
      assert msg.thread_id == "thread1"
      assert msg.message_id == "msg1"
      assert msg.author_id == "u1"
      assert msg.author_name == "alice"
      assert msg.provider == :mattermost
      assert msg.metadata == %{raw: "data"}
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

      msg = ChatBridge.to_internal(incoming)

      assert is_nil(msg.author_id)
      assert is_nil(msg.author_name)
    end

    test "metadata defaults to empty map when nil" do
      incoming = %ChatIncoming{
        text: "hi",
        external_room_id: "room3",
        external_thread_id: nil,
        external_message_id: nil,
        author: nil,
        metadata: nil
      }

      msg = ChatBridge.to_internal(incoming)
      assert msg.metadata == nil
    end
  end

  # ── resolve_roles/1 ───────────────────────────────────────────────────

  describe "resolve_roles/1" do
    test "returns {:ok, nil} when author_name is nil" do
      assert {:ok, nil} == ChatBridge.resolve_roles(%{author_name: nil})
    end

    test "returns {:ok, role_ids} for known user" do
      assert {:ok, ["role1", "role2"]} == ChatBridge.resolve_roles(%{author_name: "alice"})
    end

    test "returns {:ok, nil} for unknown user" do
      assert {:ok, nil} == ChatBridge.resolve_roles(%{author_name: "unknown"})
    end
  end
end
