defmodule Zaq.Channels.WebBridgeTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  describe "to_internal/2" do
    test "builds %Incoming{provider: :web} from params" do
      params = %{content: "hello", channel_id: "bo", session_id: "s1", request_id: "r1"}
      msg = WebBridge.to_internal(params)

      assert %Incoming{} = msg
      assert msg.content == "hello"
      assert msg.channel_id == "bo"
      assert msg.provider == :web
      assert msg.metadata.session_id == "s1"
      assert msg.metadata.request_id == "r1"
    end

    test "defaults channel_id to 'bo'" do
      params = %{content: "hi", session_id: "s1"}
      msg = WebBridge.to_internal(params)
      assert msg.channel_id == "bo"
    end
  end

  describe "send_reply/2" do
    test "broadcasts {:pipeline_result, ...} to the session PubSub topic" do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:session-abc")

      outgoing = %Outgoing{
        body: "the answer",
        channel_id: "bo",
        provider: :web,
        metadata: %{session_id: "session-abc", request_id: "req-42", user_content: "my question"}
      }

      :ok = WebBridge.send_reply(outgoing, %{})

      assert_receive {:pipeline_result, "req-42", ^outgoing, "my question"}
    end
  end

  describe "upsert_message/3" do
    test "broadcasts :answering when intent_meta stage is not an atom" do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:session-abc")

      request = %{
        request_id: "req-42",
        session_id: "session-abc",
        body: "Checking sources",
        intent_meta: %{stage: "retrieving"}
      }

      assert {:ok, %{action: :created, message_id: "req-42"}} =
               WebBridge.upsert_message(%{}, request, %{})

      assert_receive {:status_update, "req-42", :answering, "Checking sources"}
    end

    test "broadcasts :answering when intent_meta is nil" do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:session-abc")

      request = %{
        request_id: "req-43",
        session_id: "session-abc",
        body: "Generating response",
        intent_meta: nil
      }

      assert {:ok, %{action: :created, message_id: "req-43"}} =
               WebBridge.upsert_message(%{}, request, %{})

      assert_receive {:status_update, "req-43", :answering, "Generating response"}
    end
  end
end
