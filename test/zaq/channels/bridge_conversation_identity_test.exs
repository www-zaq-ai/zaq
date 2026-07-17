defmodule Zaq.Channels.BridgeConversationIdentityTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.{CommunicationBridge, EmailBridge}
  alias Zaq.Engine.Messages.Incoming

  defp incoming(attrs) do
    %{content: "hello", channel_id: "user@example.com", provider: "email:imap"}
    |> Map.merge(attrs)
    |> Incoming.new()
  end

  describe "conversation_channel_type/2" do
    test "maps email providers to the imap conversation channel" do
      assert CommunicationBridge.conversation_channel_type("email") == "email:imap"
      assert CommunicationBridge.conversation_channel_type("email:smtp") == "email:imap"
      assert CommunicationBridge.conversation_channel_type("email:imap") == "email:imap"
      assert CommunicationBridge.conversation_channel_type(:email) == "email:imap"
      assert CommunicationBridge.conversation_channel_type(:"email:smtp") == "email:imap"
    end

    test "maps web to the bo conversation channel" do
      assert CommunicationBridge.conversation_channel_type("web") == "bo"
      assert CommunicationBridge.conversation_channel_type(:web) == "bo"
    end

    test "passes other providers through unchanged" do
      assert CommunicationBridge.conversation_channel_type("mattermost") == "mattermost"
      assert CommunicationBridge.conversation_channel_type(:mattermost) == "mattermost"
    end

    test "non-atom, non-binary providers resolve to api" do
      assert CommunicationBridge.conversation_channel_type(123) == "api"
      assert CommunicationBridge.conversation_channel_type(%{}) == "api"
    end
  end

  describe "conversation_key/3 (email channel)" do
    test "prefers the email metadata thread_key" do
      msg =
        incoming(%{
          metadata: %{
            "email" => %{"thread_key" => "<root@mail.example>"},
            "thread_key" => "outer-key",
            "topic" => "campaign"
          }
        })

      assert CommunicationBridge.conversation_key(msg, "email:imap") == "<root@mail.example>"
    end

    test "falls back to the top-level thread_key" do
      msg = incoming(%{metadata: %{"thread_key" => "outer-key", "topic" => "campaign"}})

      assert CommunicationBridge.conversation_key(msg, "email:imap") == "outer-key"
    end

    test "falls back to topic then subject for outbound-first sends" do
      by_topic = incoming(%{metadata: %{"topic" => "campaign", "subject" => "Hello"}})
      by_subject = incoming(%{metadata: %{"subject" => "Hello"}})

      assert CommunicationBridge.conversation_key(by_topic, "email:imap") == "campaign"
      assert CommunicationBridge.conversation_key(by_subject, "email:imap") == "Hello"
    end

    test "skips blank strings in the precedence chain" do
      msg =
        incoming(%{
          metadata: %{
            "email" => %{"thread_key" => "  "},
            "thread_key" => "",
            "topic" => " ",
            "subject" => "Hello"
          }
        })

      assert CommunicationBridge.conversation_key(msg, "email:imap") == "Hello"
    end

    test "falls back to the normalized thread_id, then message_id" do
      by_thread = incoming(%{thread_id: "<t-1@mail.example>", message_id: "<m-1@mail.example>"})
      by_message = incoming(%{message_id: "<m-1@mail.example>"})

      assert CommunicationBridge.conversation_key(by_thread, "email:imap") == "t-1@mail.example"
      assert CommunicationBridge.conversation_key(by_message, "email:imap") == "m-1@mail.example"
    end

    test "returns nil when nothing resolves (caller owns the author fallback)" do
      msg = incoming(%{author_id: "person@example.com"})

      assert CommunicationBridge.conversation_key(msg, "email:imap") == nil
    end

    test "handles atom-keyed metadata" do
      msg = incoming(%{metadata: %{email: %{thread_key: "<root@mail.example>"}}})

      assert CommunicationBridge.conversation_key(msg, "email:imap") == "<root@mail.example>"
    end
  end

  describe "conversation_key/3 (other channels)" do
    test "returns nil for channels without a grouping callback" do
      msg = incoming(%{provider: "mattermost", metadata: %{"topic" => "campaign"}})

      assert CommunicationBridge.conversation_key(msg, "mattermost") == nil
      assert CommunicationBridge.conversation_key(msg, "bo") == nil
      assert CommunicationBridge.conversation_key(msg, "api") == nil
    end
  end

  describe "outbound_conversation_key/4" do
    test "email platforms group by topic, then subject" do
      assert CommunicationBridge.outbound_conversation_key("email", "campaign", "Hello") ==
               "campaign"

      assert CommunicationBridge.outbound_conversation_key("email:smtp", nil, "Hello") == "Hello"

      assert CommunicationBridge.outbound_conversation_key("email:imap", "campaign", nil) ==
               "campaign"
    end

    test "blank topic falls through to subject" do
      assert CommunicationBridge.outbound_conversation_key("email", "  ", "Hello") == "Hello"
    end

    test "returns nil when both topic and subject are blank" do
      assert CommunicationBridge.outbound_conversation_key("email", nil, nil) == nil
      assert CommunicationBridge.outbound_conversation_key("email", "", " ") == nil
    end

    test "non-email platforms return nil" do
      assert CommunicationBridge.outbound_conversation_key("mattermost", "campaign", "Hello") ==
               nil

      assert CommunicationBridge.outbound_conversation_key("bo", "campaign", "Hello") == nil
    end
  end

  describe "EmailBridge callbacks" do
    test "implements the optional Bridge conversation identity callbacks" do
      assert function_exported?(EmailBridge, :conversation_key, 1)
      assert function_exported?(EmailBridge, :outbound_conversation_key, 2)
    end

    test "outbound_conversation_key/2 applies topic-then-subject precedence" do
      assert EmailBridge.outbound_conversation_key("campaign", "Hello") == "campaign"
      assert EmailBridge.outbound_conversation_key(nil, "Hello") == "Hello"
      assert EmailBridge.outbound_conversation_key(nil, nil) == nil
    end
  end
end
