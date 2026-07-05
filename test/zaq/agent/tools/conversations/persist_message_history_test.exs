defmodule Zaq.Agent.Tools.Conversations.PersistMessageHistoryTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Conversations.PersistMessageHistory
  alias Zaq.Engine.Messages.Incoming

  defmodule OkRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})
      %{event | response: {:ok, %{conversation_id: "conversation-1", message_id: "message-1"}}}
    end
  end

  defmodule ErrorRouter do
    def dispatch(event), do: %{event | response: {:error, :conversation_not_found}}
  end

  defmodule StringErrorRouter do
    def dispatch(event), do: %{event | response: {:error, "engine unavailable"}}
  end

  defmodule UnexpectedRouter do
    def dispatch(event), do: %{event | response: :unexpected_response}
  end

  describe "schema/0" do
    test "exposes generic conversation and message fields" do
      keys = Keyword.keys(PersistMessageHistory.schema())

      assert :incoming in keys
      assert :message in keys
      assert :content in keys
      assert :channel_id in keys
      assert :provider in keys
      assert :conversation_id in keys
    end
  end

  describe "run/2" do
    test "dispatches a supplied Incoming struct and message attrs" do
      incoming = %Incoming{
        content: "routing only",
        channel_id: "channel-1",
        author_id: "person-1",
        provider: :mattermost
      }

      assert {:ok, %{persisted: true, conversation_id: "conversation-1", message_id: "message-1"}} =
               PersistMessageHistory.run(
                 %{incoming: incoming, message: %{content: "Assistant follow-up"}},
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :persist_message_history
      assert event.request.incoming == incoming
      assert event.request.message["content"] == "Assistant follow-up"
      assert event.request.message["role"] == "assistant"
    end

    test "builds an Incoming envelope from generic routing fields" do
      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(
                 %{
                   content: "Assistant initiated message",
                   channel_id: "destination-1",
                   provider: "mattermost",
                   metadata: %{"source" => "workflow"}
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert %Incoming{} = incoming = event.request.incoming
      assert incoming.content == "Assistant initiated message"
      assert incoming.channel_id == "destination-1"
      assert incoming.author_id == "destination-1"
      assert incoming.provider == "mattermost"
      assert Map.get(incoming.metadata, "source") == "workflow"
      assert event.request.message["content"] == "Assistant initiated message"
    end

    test "consumes NotifyPerson-style delivery aliases" do
      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(
                 %{
                   channel: "email:smtp",
                   channel_identifier: "person@example.com",
                   subject: "Follow-up topic",
                   message: "Notification body",
                   notification_log_id: 123,
                   person_id: 42
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert %Incoming{} = incoming = event.request.incoming
      assert incoming.content == "Notification body"
      assert incoming.provider == "email:smtp"
      assert incoming.channel_id == "person@example.com"
      assert incoming.author_id == "person@example.com"
      assert incoming.metadata["subject"] == "Follow-up topic"
      assert incoming.metadata["notification_log_id"] == 123
      assert event.request.message["content"] == "Notification body"
      assert event.request.message["person_id"] == 42
      assert event.request.message["metadata"]["subject"] == "Follow-up topic"
    end

    test "merges conversation_id into incoming metadata" do
      incoming = %Incoming{content: "routing", channel_id: "channel-1", provider: :mattermost}

      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(
                 %{
                   incoming: incoming,
                   content: "Follow up",
                   conversation_id: "conversation-existing"
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.request.incoming.metadata[:conversation_id] == "conversation-existing"
    end

    test "fills blank incoming map fields from top-level values" do
      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(
                 %{
                   incoming: %{
                     "content" => "",
                     "channel_id" => "existing-channel",
                     "provider" => nil,
                     "author_id" => "existing-author"
                   },
                   content: "Filled content",
                   provider: "mattermost",
                   channel_id: "fallback-channel",
                   author_id: "fallback-author"
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert %Incoming{} = incoming = event.request.incoming
      assert incoming.content == "Filled content"
      assert incoming.channel_id == "existing-channel"
      assert incoming.provider == "mattermost"
      assert incoming.author_id == "existing-author"
    end

    test "validates message content after receiving a valid Incoming struct" do
      incoming = %Incoming{content: "routing", channel_id: "c1", provider: :mattermost}

      assert {:error, "message content is required"} =
               PersistMessageHistory.run(%{incoming: incoming}, %{node_router: OkRouter})

      refute_received {:dispatched, _event}
    end

    test "derives person_id from atom-keyed person maps" do
      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(
                 %{
                   content: "Message",
                   channel_id: "c1",
                   provider: "mattermost",
                   person: %{id: 42}
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.request.message["person_id"] == 42
    end

    test "derives person_id from string-keyed person maps" do
      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(
                 %{
                   content: "Message",
                   channel_id: "c1",
                   provider: "mattermost",
                   person: %{"id" => 43}
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.request.message["person_id"] == 43
    end

    test "merges conversation_id into constructed incoming metadata" do
      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(
                 %{
                   content: "Follow up",
                   channel_id: "channel-1",
                   provider: "mattermost",
                   conversation_id: "conversation-existing",
                   metadata: %{"source" => "workflow"}
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert %Incoming{} = incoming = event.request.incoming
      assert incoming.metadata["conversation_id"] == "conversation-existing"
      assert incoming.metadata["source"] == "workflow"
    end

    # NOTE: The rescue clauses in new_incoming/1 are not realistically reachable via
    # public run/2 because validate_routing_attrs/1 rejects missing routing fields
    # before Incoming.new/1 is called.

    test "returns engine error strings unchanged" do
      assert {:error, "engine unavailable"} =
               PersistMessageHistory.run(
                 %{content: "Follow up", channel_id: "c1", provider: "mattermost"},
                 %{node_router: StringErrorRouter}
               )
    end

    test "formats unexpected engine responses" do
      assert {:error, "persist_message_history_failed::unexpected_response"} =
               PersistMessageHistory.run(
                 %{content: "Follow up", channel_id: "c1", provider: "mattermost"},
                 %{node_router: UnexpectedRouter}
               )
    end

    test "returns validation errors before dispatching" do
      assert {:error, "message content is required"} =
               PersistMessageHistory.run(%{channel_id: "c1", provider: "mattermost"}, %{
                 node_router: OkRouter
               })

      refute_received {:dispatched, _event}
    end

    test "does not require routing aliases when Incoming is supplied" do
      incoming = %Incoming{content: "routing", channel_id: "c1", provider: :mattermost}

      assert {:ok, %{persisted: true}} =
               PersistMessageHistory.run(%{incoming: incoming, content: "Message"}, %{
                 node_router: OkRouter
               })
    end

    test "returns routing validation errors before dispatching" do
      assert {:error, "provider or channel is required"} =
               PersistMessageHistory.run(%{content: "Message", channel_id: "c1"}, %{
                 node_router: OkRouter
               })

      assert {:error, "channel_id or channel_identifier is required"} =
               PersistMessageHistory.run(%{content: "Message", provider: "mattermost"}, %{
                 node_router: OkRouter
               })

      refute_received {:dispatched, _event}
    end

    test "formats engine errors" do
      assert {:error, ":conversation_not_found"} =
               PersistMessageHistory.run(
                 %{content: "Follow up", channel_id: "c1", provider: "mattermost"},
                 %{node_router: ErrorRouter}
               )
    end
  end
end
