defmodule Zaq.Engine.EventsTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Events

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:node_router_dispatch, event})
      %{event | response: :ok}
    end
  end

  test "build_invoke_event forwards type and event opts" do
    request = %{request_id: "r-1"}
    action = :invoke

    event =
      Events.build_invoke_event(request, action,
        type: :async,
        event_opts: [trace_id: "t-1"]
      )

    assert %Zaq.Event{} = event
    assert event.next_hop.destination == :engine
    assert event.next_hop.type == :async
    assert event.opts[:action] == :invoke
    assert event.opts[:trace_id] == "t-1"
  end

  test "build_and_dispatch_invoke_event forwards options to dispatch" do
    request = %{request_id: "r-2"}
    action = :invoke

    event =
      Events.build_and_dispatch_invoke_event(request, action,
        node_router: StubNodeRouter,
        type: :sync,
        event_opts: [trace_id: "t-2"]
      )

    assert event.response == :ok

    assert_received {:node_router_dispatch, %Zaq.Event{} = dispatched_event}

    assert dispatched_event.next_hop.destination == :engine
    assert dispatched_event.next_hop.type == :sync
    assert dispatched_event.opts[:action] == :invoke
    assert dispatched_event.opts[:trace_id] == "t-2"
  end

  test "build_and_dispatch_invoke_event/2 uses default opts and default node router" do
    request = %{request_id: "r-default"}
    action = :invoke

    event = Events.build_and_dispatch_invoke_event(request, action)

    assert %Zaq.Event{} = event
    assert event.request == request
    assert [%Zaq.EventHop{destination: :engine, type: :sync}] = event.hops
    assert event.opts[:action] == :invoke
    assert event.response == {:error, {:invalid_request, request}}
  end
end
