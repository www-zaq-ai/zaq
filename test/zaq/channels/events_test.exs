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

  test "build_upsert_message_event maps atom-key params into outgoing struct" do
    params = %{
      provider: :web,
      channel_id: "c1",
      thread_id: "t1",
      body: "hello",
      request_id: "r1",
      status_message_id: "sm1",
      update_intent: :refresh,
      intent_meta: %{reason: "sync"},
      session_id: "s1",
      message_id: "m1"
    }

    event = Events.build_upsert_message_event(params)

    assert event.opts[:action] == :upsert_message
    assert event.next_hop.type == :async
    assert match?(%Outgoing{}, event.request)

    assert event.request.provider == :web
    assert event.request.channel_id == "c1"
    assert event.request.thread_id == "t1"
    assert event.request.body == "hello"

    assert event.request.metadata == %{
             request_id: "r1",
             status_message_id: "sm1",
             update_intent: :refresh,
             intent_meta: %{reason: "sync"},
             session_id: "s1",
             message_id: "m1"
           }
  end

  test "build_upsert_message_event maps string-key params into outgoing struct" do
    params = %{
      "provider" => :web,
      "channel_id" => "c1",
      "thread_id" => "t1",
      "body" => "hello",
      "request_id" => "r1",
      "status_message_id" => "sm1",
      "update_intent" => :refresh,
      "intent_meta" => %{reason: "sync"},
      "session_id" => "s1",
      "message_id" => "m1"
    }

    event = Events.build_upsert_message_event(params)

    assert event.opts[:action] == :upsert_message
    assert event.next_hop.type == :async
    assert event.request.provider == :web
    assert event.request.channel_id == "c1"
    assert event.request.thread_id == "t1"
    assert event.request.body == "hello"
    assert event.request.metadata.status_message_id == "sm1"
    assert event.request.metadata.request_id == "r1"
    assert event.request.metadata.update_intent == :refresh
    assert event.request.metadata.intent_meta == %{reason: "sync"}
    assert event.request.metadata.session_id == "s1"
    assert event.request.metadata.message_id == "m1"
  end

  test "build_upsert_message_event keeps missing optional map keys nil and sync" do
    params = %{
      "channel_id" => "c1",
      request_id: "r1",
      message_id: "m1",
      body: "hello",
      provider: :web
    }

    event = Events.build_upsert_message_event(params)

    assert event.opts[:action] == :upsert_message
    assert event.next_hop.type == :sync
    assert event.request.provider == :web
    assert event.request.channel_id == "c1"
    assert event.request.thread_id == nil
    assert event.request.metadata.status_message_id == nil
    assert event.request.metadata.update_intent == nil
    assert event.request.metadata.intent_meta == nil
    assert event.request.metadata.session_id == nil
  end

  test "build_and_dispatch_upsert_message_event dispatches built event" do
    event =
      Events.build_and_dispatch_upsert_message_event(
        %{
          "provider" => :web,
          "channel_id" => "c1",
          "thread_id" => "t1",
          "body" => "hello",
          "request_id" => "r1",
          "status_message_id" => "sm1",
          "update_intent" => :refresh,
          "intent_meta" => %{reason: "sync"},
          "session_id" => "s1",
          "message_id" => "m1"
        },
        node_router: StubNodeRouter
      )

    assert event.response == :ok

    assert_received {:node_router_dispatch,
                     %Zaq.Event{opts: [action: :upsert_message], request: %Outgoing{} = request}}

    assert request.provider == :web
    assert request.channel_id == "c1"
    assert request.thread_id == "t1"
    assert request.metadata.status_message_id == "sm1"
    assert request.metadata.message_id == "m1"
    assert event.next_hop.type == :async
  end
end
