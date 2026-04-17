defmodule Zaq.EventTest do
  use ExUnit.Case, async: true

  alias Zaq.{Event, EventHop}

  test "new/3 builds an event with defaults" do
    event = Event.new(%{hello: "world"}, :agent)

    assert event.request == %{hello: "world"}
    assert %EventHop{destination: :agent, type: :sync} = event.next_hop
    assert is_binary(event.trace_id)
    assert event.opts == []
    assert event.version == 1
    assert event.assigns == %{}
    assert event.response == nil
    assert event.hops == []
    assert event.actor == nil
  end

  test "new/3 allows overriding event attributes" do
    now = DateTime.utc_now()

    event =
      Event.new(%{hello: "world"}, :channels,
        type: :async,
        timestamp: now,
        trace_id: "trace-id",
        actor: %{id: "u1"},
        opts: [action: :deliver_outgoing],
        version: 2
      )

    assert %EventHop{destination: :channels, type: :async, timestamp: ^now} = event.next_hop
    assert event.trace_id == "trace-id"
    assert event.actor == %{id: "u1"}
    assert event.opts == [action: :deliver_outgoing]
    assert event.version == 2
  end
end
