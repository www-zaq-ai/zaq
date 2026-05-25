defmodule Zaq.BO.EventsTest do
  use ExUnit.Case, async: true

  alias Zaq.BO.Events

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:node_router_dispatch, event})
      %{event | response: :ok}
    end
  end

  @request %{module: String, function: :upcase, args: ["hi"]}

  test "build_invoke_event/3 delegates through helper and returns BO invoke event" do
    event =
      Events.build_invoke_event(@request, :invoke,
        type: :async,
        event_opts: [request_id: "req-1"]
      )

    assert %Zaq.Event{} = event
    assert event.next_hop.destination == :bo
    assert event.next_hop.type == :async
    assert event.opts[:action] == :invoke
    assert event.opts[:request_id] == "req-1"
  end

  test "build_and_dispatch_invoke_event/3 delegates + dispatches via injected node router" do
    event =
      Events.build_and_dispatch_invoke_event(@request, :invoke,
        node_router: StubNodeRouter,
        type: :sync,
        event_opts: [request_id: "req-2"]
      )

    assert event.response == :ok
    assert_received {:node_router_dispatch, dispatched_event}
    assert dispatched_event.next_hop.destination == :bo
    assert dispatched_event.opts[:action] == :invoke
    assert dispatched_event.next_hop.type == :sync
    assert dispatched_event.opts[:request_id] == "req-2"
  end

  test "build_and_dispatch_invoke_event/2 uses default opts wrapper and dispatch path" do
    event = Events.build_and_dispatch_invoke_event(@request, :invoke)

    assert %Zaq.Event{} = event
    assert event.request == @request
    assert [%Zaq.EventHop{destination: :bo, type: :sync}] = event.hops
    assert event.opts[:action] == :invoke
    assert event.response == String.upcase("hi")
  end
end
