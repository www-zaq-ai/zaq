defmodule Zaq.Agent.EventsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Events

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:node_router_dispatch, event})
      %{event | response: :ok}
    end
  end

  @request %{request_id: "r1", payload: "hello"}
  @action :answer
  @event_opts [source: :test]

  test "build_invoke_event builds an agent-destination invoke event" do
    event = Events.build_invoke_event(@request, @action, type: :async, event_opts: @event_opts)

    assert %Zaq.Event{} = event
    assert event.request == @request
    assert event.next_hop.destination == :agent
    assert event.next_hop.type == :async
    assert event.opts[:action] == @action
    assert event.opts[:source] == :test
  end

  test "build_and_dispatch_invoke_event dispatches the built agent event" do
    event =
      Events.build_and_dispatch_invoke_event(@request, @action,
        node_router: StubNodeRouter,
        type: :sync
      )

    assert event.response == :ok
    assert_received {:node_router_dispatch, %Zaq.Event{} = dispatched}
    assert dispatched.next_hop.destination == :agent
    assert dispatched.next_hop.type == :sync
    assert dispatched.opts[:action] == @action
  end

  test "build_and_dispatch_invoke_event/2 uses default opts and default node router" do
    event = Events.build_and_dispatch_invoke_event(@request, @action)

    assert %Zaq.Event{} = event
    assert event.request == @request
    assert [%Zaq.EventHop{destination: :agent, type: :sync}] = event.hops
    assert event.opts[:action] == @action
    assert event.response == {:error, {:unsupported_action, @action}}
  end
end
