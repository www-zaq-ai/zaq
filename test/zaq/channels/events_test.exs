defmodule Zaq.Channels.EventsTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Events
  alias Zaq.Engine.Messages.Outgoing

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:node_router_dispatch, event})
      %{event | response: :ok}
    end
  end

  test "build_upsert_message_event forces sync when message_id missing" do
    event =
      Events.build_upsert_message_event(%Outgoing{
        provider: :web,
        channel_id: "c1",
        body: "hello",
        metadata: %{request_id: "r1"}
      })

    assert event.next_hop.type == :sync
    assert event.opts[:action] == :upsert_message
  end

  test "build_upsert_message_event defaults to async when status_message_id atom key is present" do
    event =
      Events.build_upsert_message_event(%Outgoing{
        provider: :web,
        channel_id: "c1",
        body: "hello",
        metadata: %{request_id: "r1", status_message_id: "m1"}
      })

    assert event.next_hop.type == :async
    assert event.opts[:action] == :upsert_message
  end

  test "build_upsert_message_event defaults to async when status_message_id string key is present" do
    event =
      Events.build_upsert_message_event(%Outgoing{
        provider: :web,
        channel_id: "c1",
        body: "hello",
        metadata: %{"request_id" => "r1", "status_message_id" => "m1"}
      })

    assert event.next_hop.type == :async
    assert event.opts[:action] == :upsert_message
  end

  test "build_upsert_message_event defaults to sync when message_id is present without status_message_id" do
    event =
      Events.build_upsert_message_event(%Outgoing{
        provider: :web,
        channel_id: "c1",
        body: "hello",
        metadata: %{request_id: "r1", message_id: "m1"}
      })

    assert event.next_hop.type == :sync
    assert event.opts[:action] == :upsert_message
  end

  test "build_upsert_message_event honors explicit type override even when status_message_id would imply async" do
    event =
      Events.build_upsert_message_event(
        %Outgoing{
          provider: :web,
          channel_id: "c1",
          body: "hello",
          metadata: %{request_id: "r1", status_message_id: "m1"}
        },
        type: :sync
      )

    assert event.next_hop.type == :sync
    assert event.opts[:action] == :upsert_message
  end

  test "build_and_dispatch_upsert_message_event dispatches built event" do
    event =
      Events.build_and_dispatch_upsert_message_event(
        %Outgoing{provider: :web, channel_id: "c1", body: "hello", metadata: %{request_id: "r1"}},
        node_router: StubNodeRouter
      )

    assert event.response == :ok

    assert_received {:node_router_dispatch,
                     %Zaq.Event{opts: [action: :upsert_message], next_hop: hop}}

    assert hop.type == :sync
  end
end
