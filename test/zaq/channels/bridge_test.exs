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

  defmodule StubAgentSelection do
    def get_conversation_enabled_agent(10), do: {:error, :conversation_disabled}
    def get_conversation_enabled_agent(20), do: {:ok, %{id: 20}}
    def get_conversation_enabled_agent(_), do: {:error, :agent_not_found}
  end

  defmodule PassThroughBridge do
    def handle_from_listener(config, payload, sink_opts), do: {:ok, {config, payload, sink_opts}}
  end

  defmodule HookedBridge do
    def before_incoming(config, payload, sink_opts, _bridge_module) do
      {:ok,
       {Map.put(config, :hooked, true), Map.put(payload, "hooked", true),
        Keyword.put(sink_opts, :hooked, true)}}
    end

    def after_incoming(_config, _payload, _sink_opts, {:ok, {_c, _p, _s}}, _bridge_module),
      do: :ok

    def handle_from_listener(config, payload, sink_opts), do: {:ok, {config, payload, sink_opts}}
  end

  defmodule ErrorBeforeHookBridge do
    def before_incoming(_config, _payload, _sink_opts, _bridge_module), do: {:error, :blocked}
    def handle_from_listener(_config, _payload, _sink_opts), do: :ok
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

  test "first_active_selection/2 returns first conversation-enabled candidate" do
    candidates = [
      {:channel_assignment, 10},
      {:provider_default, 20},
      {:global_default, 30}
    ]

    assert %{"agent_id" => 20, "source" => "provider_default"} =
             Bridge.first_active_selection(candidates, StubAgentSelection)
  end

  test "route_incoming/4 default hooks pass through inputs" do
    config = %{provider: "email:imap"}
    payload = %{"body_text" => "hello"}
    sink_opts = [mailbox: "INBOX"]

    assert {:ok, {^config, ^payload, ^sink_opts}} =
             Bridge.route_incoming(PassThroughBridge, config, payload, sink_opts)
  end

  test "route_incoming/4 applies override hooks and after hook result" do
    assert :ok =
             Bridge.route_incoming(
               HookedBridge,
               %{provider: "email:imap"},
               %{"body_text" => "hello"},
               mailbox: "INBOX"
             )
  end

  test "route_incoming/4 propagates before hook errors" do
    assert {:error, :blocked} =
             Bridge.route_incoming(
               ErrorBeforeHookBridge,
               %{provider: "email:imap"},
               %{"body_text" => "hello"},
               mailbox: "INBOX"
             )
  end

  test "ack_from_event_response/1 normalizes ack values" do
    assert :ok = Bridge.ack_from_event_response(:ok)
    assert :ok = Bridge.ack_from_event_response(%{ack: :ok})
    assert :ok = Bridge.ack_from_event_response(%{"ack" => {:ok, :queued}})
    assert {:error, :no_ack} = Bridge.ack_from_event_response({:error, :no_ack})
    assert {:error, {:invalid_ack, :queued}} = Bridge.ack_from_event_response(:queued)
  end
end
