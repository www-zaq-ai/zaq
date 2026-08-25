defmodule Zaq.Storage.EventsTest do
  use ExUnit.Case, async: true

  alias Zaq.Storage.Events

  test "build_materialize_document_event names the storage role and the fixed action" do
    event = Events.build_materialize_document_event(%{file_id: "disk:archives:guide.md"})

    assert event.next_hop.destination == :storage
    assert event.next_hop.type == :sync
    assert event.opts[:action] == :materialize_document
    assert event.request == %{file_id: "disk:archives:guide.md"}
    refute event.response
  end

  test "build_materialize_document_event carries event opts through" do
    event =
      Events.build_materialize_document_event(%{file_id: "guide.md"},
        type: :async,
        event_opts: [reply_to: :caller],
        config: __MODULE__.ConfigStub
      )

    assert event.next_hop.type == :async
    assert event.opts[:action] == :materialize_document
    assert event.opts[:reply_to] == :caller
    assert event.opts[:config] == __MODULE__.ConfigStub
  end
end
