defmodule Zaq.Agent.StatusTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Status
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  # Executes the event's request locally — avoids real RPC in unit tests.
  defmodule FakeNodeRouter do
    alias Zaq.Event

    def dispatch(%Event{request: %{module: mod, function: fun, args: args}} = event) do
      apply(mod, fun, args)
      event
    end
  end

  describe "broadcast/4 with %Incoming{}" do
    test "broadcasts {:status_update, request_id, stage, message} to the correct topic" do
      session_id = "test-session-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session_id}")

      incoming = %Incoming{
        content: "hi",
        channel_id: "bo",
        provider: :web,
        metadata: %{session_id: session_id, request_id: request_id}
      }

      assert :ok = Status.broadcast(incoming, :validating, "Checking…", FakeNodeRouter)
      assert_receive {:status_update, ^request_id, :validating, "Checking…"}
    end

    test "no-ops silently when session_id is absent from metadata" do
      incoming = %Incoming{
        content: "hi",
        channel_id: "bo",
        provider: :web,
        metadata: %{}
      }

      assert :ok = Status.broadcast(incoming, :validating, "x", FakeNodeRouter)
    end

    test "no-ops silently when request_id is absent from metadata" do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session_id}")

      incoming = %Incoming{
        content: "hi",
        channel_id: "bo",
        provider: :web,
        metadata: %{session_id: session_id}
      }

      assert :ok = Status.broadcast(incoming, :validating, "x", FakeNodeRouter)
      refute_receive {:status_update, _, _, _}
    end
  end

  describe "broadcast/4 with context map" do
    test "broadcasts when session_id and request_id are present" do
      session_id = "ctx-session-#{System.unique_integer([:positive])}"
      request_id = "ctx-req-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session_id}")

      ctx = %{session_id: session_id, request_id: request_id}
      assert :ok = Status.broadcast(ctx, :retrieving, "Searching…", FakeNodeRouter)
      assert_receive {:status_update, ^request_id, :retrieving, "Searching…"}
    end
  end

  describe "broadcast/4 with nil" do
    test "returns :ok and does not crash" do
      assert :ok = Status.broadcast(nil, :validating, "x", FakeNodeRouter)
    end
  end

  describe "context_from_event/1" do
    test "extracts context when request carries valid session and request ids" do
      event =
        Event.new(
          %Incoming{
            content: "hi",
            channel_id: "bo",
            provider: :web,
            metadata: %{session_id: "s1", request_id: "r1"}
          },
          :agent,
          opts: [node_router: FakeNodeRouter]
        )

      assert %{session_id: "s1", request_id: "r1", node_router: FakeNodeRouter} =
               Status.context_from_event(event)
    end

    test "returns nil when event is nil or missing required ids" do
      assert Status.context_from_event(nil) == nil

      missing_session =
        Event.new(
          %Incoming{
            content: "hi",
            channel_id: "bo",
            provider: :web,
            metadata: %{request_id: "r1"}
          },
          :agent
        )

      missing_request =
        Event.new(
          %Incoming{
            content: "hi",
            channel_id: "bo",
            provider: :web,
            metadata: %{session_id: "s1"}
          },
          :agent
        )

      assert Status.context_from_event(missing_session) == nil
      assert Status.context_from_event(missing_request) == nil
    end
  end
end
