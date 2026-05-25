defmodule Zaq.Events.HelperTest do
  use ExUnit.Case, async: true

  alias Zaq.Events.Helper

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})
      %{event | response: :ok}
    end
  end

  @request %{message: "hello"}

  test "build_invoke_event/4 builds sync event with default options" do
    event = Helper.build_invoke_event(:agent, @request, :run)

    assert %Zaq.Event{} = event
    assert event.request == @request
    assert event.next_hop.destination == :agent
    assert event.next_hop.type == :sync
    assert event.opts == [action: :run]
    assert event.response == nil
  end

  test "build_invoke_event/4 applies custom type and appends event_opts after action" do
    event =
      Helper.build_invoke_event(:agent, @request, :run,
        type: :async,
        event_opts: [trace: "t1", actor: :system]
      )

    assert event.next_hop.type == :async
    assert event.opts == [action: :run, trace: "t1", actor: :system]
  end

  test "build_and_dispatch_invoke_event/4 dispatches through injected node_router" do
    event =
      Helper.build_and_dispatch_invoke_event(:agent, @request, :run,
        node_router: StubNodeRouter,
        type: :async,
        event_opts: [trace: "t1"]
      )

    assert event.response == :ok
    assert_received {:dispatched, %Zaq.Event{} = dispatched}
    assert dispatched.request == @request
    assert dispatched.next_hop.destination == :agent
    assert dispatched.next_hop.type == :async
    assert dispatched.opts == [action: :run, trace: "t1"]
  end

  test "build_and_dispatch_invoke_event/4 uses default node_router when not injected" do
    event = Helper.build_and_dispatch_invoke_event(:agent, @request, :run)

    assert event.response == {:error, {:unsupported_action, :run}}
  end
end
