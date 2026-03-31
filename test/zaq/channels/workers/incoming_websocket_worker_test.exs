defmodule Zaq.Channels.Workers.IncomingChatWorkerTest do
  use Zaq.DataCase, async: false

  alias Jido.Chat.Author
  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Zaq.Channels.Workers.IncomingChatWorker

  # ── Stub adapters ─────────────────────────────────────────────────────

  defmodule StubAdapter do
    def transform_incoming(_payload, _opts) do
      {:ok,
       %ChatIncoming{
         text: "hello world",
         external_room_id: "chan-1",
         external_thread_id: nil,
         external_message_id: "msg-1",
         author: %Author{user_id: "u1", user_name: "alice"},
         metadata: %{}
       }}
    end
  end

  defmodule BotAdapter do
    def transform_incoming(_payload, _opts) do
      {:ok,
       %ChatIncoming{
         text: "bot message",
         external_room_id: "chan-1",
         external_thread_id: nil,
         author: %Author{user_id: "bot-1", user_name: "bot"},
         metadata: %{}
       }}
    end
  end

  defmodule ErrorAdapter do
    def transform_incoming(_payload, _opts), do: {:error, :bad_payload}
  end

  # ── Stub JidoChatBridge dependencies ─────────────────────────────────

  defmodule StubHooks do
    def dispatch_before(_event, _payload, _ctx), do: :ok
  end

  defmodule StubPipeline do
    alias Zaq.Engine.Messages.{Incoming, Outgoing}

    def run(%Incoming{} = incoming, _opts) do
      %Outgoing{
        body: "stub answer",
        channel_id: incoming.channel_id,
        provider: incoming.provider,
        metadata: %{answer: "stub answer", confidence_score: 0.9, latency_ms: 42}
      }
    end
  end

  defmodule StubRouter do
    alias Zaq.Engine.Messages.Outgoing

    def deliver(%Outgoing{}), do: :ok
  end

  defmodule StubConversations do
    def persist_from_incoming(_msg, _result), do: :ok
  end

  defmodule StubAccounts do
    def get_user_by_username(_), do: nil
  end

  defmodule StubPermissions do
    def list_accessible_role_ids(_user), do: []
  end

  # ── Setup ─────────────────────────────────────────────────────────────

  @base_job_args %{
    "adapter_name" => "mattermost",
    "bot_user_id" => nil,
    "transport" => "websocket",
    "config" => %{"url" => "http://mm.example.com", "token" => "tok"}
  }

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{adapter: StubAdapter}
    })

    Application.put_env(:zaq, :pipeline_hooks_module, StubHooks)
    Application.put_env(:zaq, :chat_bridge_pipeline_module, StubPipeline)
    Application.put_env(:zaq, :chat_bridge_router_module, StubRouter)
    Application.put_env(:zaq, :chat_bridge_conversations_module, StubConversations)
    Application.put_env(:zaq, :chat_bridge_accounts_module, StubAccounts)
    Application.put_env(:zaq, :chat_bridge_permissions_module, StubPermissions)

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end

      Application.delete_env(:zaq, :pipeline_hooks_module)
      Application.delete_env(:zaq, :chat_bridge_pipeline_module)
      Application.delete_env(:zaq, :chat_bridge_router_module)
      Application.delete_env(:zaq, :chat_bridge_conversations_module)
      Application.delete_env(:zaq, :chat_bridge_accounts_module)
      Application.delete_env(:zaq, :chat_bridge_permissions_module)
    end)

    :ok
  end

  # ── enqueue/3 ─────────────────────────────────────────────────────────

  describe "enqueue/3" do
    test "inserts an Oban job with serialized payload" do
      config = %{
        provider: "mattermost",
        url: "http://mm.example.com",
        token: "tok",
        bot_user_id: "bot-1"
      }

      payload = %{"post_id" => "abc", "user_id" => "u1"}

      assert {:ok, job} = IncomingChatWorker.enqueue(config, payload, transport: "websocket")
      assert job.args["adapter_name"] == "mattermost"
      assert job.args["transport"] == "websocket"
      assert job.args["bot_user_id"] == "bot-1"
      assert is_map(job.args["payload"])
    end

    test "serializes atom keys in payload to strings" do
      config = %{provider: "mattermost", url: "http://ex.com", token: "tok", bot_user_id: nil}
      payload = %{post_id: "abc", user_id: :u1}

      assert {:ok, job} = IncomingChatWorker.enqueue(config, payload, [])
      assert job.args["payload"]["post_id"] == "abc"
      assert job.args["payload"]["user_id"] == "u1"
    end

    test "defaults transport to 'unknown' when not provided" do
      config = %{provider: "mattermost", url: "http://ex.com", token: "tok", bot_user_id: nil}

      assert {:ok, job} = IncomingChatWorker.enqueue(config, %{}, [])
      assert job.args["transport"] == "unknown"
    end
  end

  # ── perform/1 ─────────────────────────────────────────────────────────

  describe "perform/1" do
    test "returns {:error, reason} when adapter transform_incoming fails" do
      Application.put_env(:zaq, :channels, %{mattermost: %{adapter: ErrorAdapter}})

      job = %Oban.Job{args: Map.put(@base_job_args, "payload", %{})}
      assert {:error, :bad_payload} = IncomingChatWorker.perform(job)
    end

    test "returns :ok and skips bridge when message is from bot" do
      Application.put_env(:zaq, :channels, %{mattermost: %{adapter: BotAdapter}})

      job = %Oban.Job{args: Map.put(@base_job_args, "payload", %{}) |> Map.put("bot_user_id", "bot-1")}
      assert :ok = IncomingChatWorker.perform(job)
    end

    test "returns :ok and calls bridge for non-bot messages" do
      job = %Oban.Job{args: Map.put(@base_job_args, "payload", %{})}
      assert :ok = IncomingChatWorker.perform(job)
    end

    test "returns :ok when bot_user_id is nil (no bot filtering)" do
      job = %Oban.Job{args: Map.put(@base_job_args, "payload", %{})}
      assert :ok = IncomingChatWorker.perform(job)
    end
  end
end
