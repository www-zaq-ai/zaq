defmodule Zaq.Channels.EventNamesTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.EventNames
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Messages.Incoming.RoutingContext

  test "message_received builds agent-requested inbound channel event names" do
    incoming = incoming(provider: :mattermost, channel_config_id: "Team Inbox")

    assert EventNames.message_received(incoming, :agent_requested) ==
             "channels:message_received.agent_requested.mattermost.team_inbox"
  end

  test "message_received builds workflow-only inbound channel event names" do
    incoming = incoming(provider: "Jido Chat", channel_config_id: "chat-42")

    assert EventNames.message_received(incoming, :workflow_only) ==
             "channels:message_received.workflow_only.jido_chat.chat_42"
  end

  test "message_received honors explicit channel_config_id option" do
    incoming = incoming(provider: :email, channel_config_id: "metadata-id")

    assert EventNames.message_received(incoming, :workflow_only, channel_config_id: "opt-id") ==
             "channels:message_received.workflow_only.email.opt_id"
  end

  test "message_received reads channel config id from incoming routing context" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      routing_context: %RoutingContext{channel_config_id: 42}
    }

    assert EventNames.message_received(incoming, :agent_requested) ==
             "channels:message_received.agent_requested.mattermost.42"
  end

  test "channel_config_id reads atom channel config id from map routing context" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      routing_context: %{channel_config_id: "map-context-id"}
    }

    assert EventNames.channel_config_id(incoming, "fallback-id") == "map-context-id"
  end

  test "channel_config_id reads string channel config id from map routing context" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      routing_context: %{"channel_config_id" => "string-map-context-id"}
    }

    assert EventNames.channel_config_id(incoming, "fallback-id") == "string-map-context-id"
  end

  test "channel_config_id ignores unsupported routing context and falls back to metadata" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      routing_context: :legacy_context,
      metadata: %{"channel_config_id" => "metadata-id"}
    }

    assert EventNames.channel_config_id(incoming, "fallback-id") == "metadata-id"
  end

  test "channel_config_id returns fallback when routing context is unsupported and metadata has no id" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      routing_context: :legacy_context,
      metadata: %{}
    }

    assert EventNames.channel_config_id(incoming, "fallback-id") == "fallback-id"
  end

  test "agent_response_delivering prefers outgoing channel config id" do
    incoming = incoming(provider: :mattermost, channel_config_id: "incoming-id")
    outgoing = outgoing(provider: :mattermost, channel_config_id: "outgoing-id")

    assert EventNames.agent_response_delivering(outgoing, incoming) ==
             "channels:agent_response.delivering.mattermost.outgoing_id"
  end

  test "agent_response_delivering falls back to original request channel config id" do
    incoming = incoming(provider: :mattermost, channel_config_id: "incoming-id")
    outgoing = %Outgoing{body: "hello", channel_id: "c1", provider: :mattermost}

    assert EventNames.agent_response_delivering(outgoing, incoming) ==
             "channels:agent_response.delivering.mattermost.incoming_id"
  end

  test "agent_response_delivering ignores unknown outgoing channel config id for fallback" do
    incoming = incoming(provider: :mattermost, channel_config_id: "incoming-id")
    outgoing = outgoing(provider: :mattermost, channel_config_id: "unknown")

    assert EventNames.agent_response_delivering(outgoing, incoming) ==
             "channels:agent_response.delivering.mattermost.incoming_id"
  end

  test "agent_response_delivering falls back to incoming routing context" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "c1",
      provider: :mattermost,
      routing_context: %RoutingContext{channel_config_id: 42}
    }

    outgoing = outgoing(provider: :mattermost, channel_config_id: "unknown")

    assert EventNames.agent_response_delivering(outgoing, incoming) ==
             "channels:agent_response.delivering.mattermost.42"
  end

  test "channel_config_id returns fallback for unsupported payloads" do
    assert EventNames.channel_config_id(:not_a_channel_payload, "fallback-id") ==
             "fallback-id"

    assert EventNames.channel_config_id(nil, "fallback-id") == "fallback-id"
  end

  test "channel_config_id ignores blank string ids" do
    assert EventNames.channel_config_id(%{"channel_config_id" => "   "}, "fallback-id") ==
             "fallback-id"
  end

  test "channel_config_id accepts integer ids" do
    assert EventNames.channel_config_id(%{channel_config_id: 42}, "fallback-id") == 42
  end

  test "part normalizes blank and non-alphanumeric values" do
    assert EventNames.part("  ") == "unknown"
    assert EventNames.part("Team #1 / Support") == "team_1_support"
  end

  defp incoming(attrs) do
    Incoming.new(%{
      content: "hello",
      channel_id: "c1",
      provider: Keyword.fetch!(attrs, :provider),
      channel_config_id: Keyword.fetch!(attrs, :channel_config_id)
    })
  end

  defp outgoing(attrs) do
    %Outgoing{
      body: "hello",
      channel_id: "c1",
      provider: Keyword.fetch!(attrs, :provider),
      metadata: %{
        "telemetry_dimensions" => %{
          "channel_config_id" => Keyword.fetch!(attrs, :channel_config_id)
        }
      }
    }
  end
end
