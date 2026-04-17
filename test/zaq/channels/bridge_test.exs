defmodule Zaq.Channels.BridgeTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Bridge
  alias Zaq.Engine.Messages.Incoming

  defmodule StubConversations do
    def persist_from_incoming(incoming, metadata) do
      send(self(), {:stub_persist, incoming, metadata})
      :ok
    end
  end

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:dispatch_called, event})
      %{event | response: :ok}
    end
  end

  test "calls override conversations module directly" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}
    metadata = %{answer: "ok"}

    assert :ok = Bridge.persist_from_incoming(incoming, metadata, StubConversations, %{id: "u1"})
    assert_received {:stub_persist, ^incoming, ^metadata}
  end

  test "dispatches through node router for default conversations module" do
    incoming = %Incoming{content: "hello", channel_id: "chan-1", provider: :mattermost}

    metadata = %{
      answer: "response",
      confidence_score: 0.9,
      latency_ms: 10,
      prompt_tokens: 1,
      completion_tokens: 1,
      total_tokens: 2
    }

    assert :ok =
             Bridge.persist_from_incoming(
               incoming,
               metadata,
               Zaq.Engine.Conversations,
               %{id: "user-1", provider: :mattermost},
               StubNodeRouter
             )

    assert_received {:dispatch_called, event}
    assert event.next_hop.destination == :engine
    assert event.opts[:action] == :persist_from_incoming
  end
end
