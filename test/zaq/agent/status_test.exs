defmodule Zaq.Agent.StatusTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Status
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  # Executes the event's request locally — avoids real RPC in unit tests.
  defmodule FakeNodeRouter do
    alias Zaq.Event

    def dispatch(%Event{opts: opts, request: request} = event) do
      if opts[:action] == :upsert_message do
        session_id = request[:session_id]
        request_id = request[:request_id]
        message = request[:body]
        stage = get_in(request, [:intent_meta, :stage]) || :answering

        if is_binary(session_id) and session_id != "" do
          Phoenix.PubSub.broadcast(
            Zaq.PubSub,
            "chat:#{session_id}",
            {:status_update, request_id, stage, message}
          )
        else
          send(self(), {:status_update, request_id, stage, message})
        end

        %{event | response: {:ok, %{action: :created, message_id: request_id}}}
      else
        event
      end
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

      assert %Incoming{metadata: %{status_message_id: ^request_id}} =
               Status.broadcast(incoming, :validating, "Checking…", FakeNodeRouter)

      assert_receive {:status_update, ^request_id, :validating, "Checking…"}
    end

    test "no-ops silently when session_id is absent from metadata" do
      incoming = %Incoming{
        content: "hi",
        channel_id: "bo",
        provider: :web,
        metadata: %{}
      }

      assert %Incoming{} = Status.broadcast(incoming, :validating, "x", FakeNodeRouter)
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

      assert %Incoming{} = Status.broadcast(incoming, :validating, "x", FakeNodeRouter)
      refute_receive {:status_update, _, _, _}
    end
  end

  describe "broadcast/4 strictness" do
    test "raises when called with map context" do
      assert_raise ArgumentError, fn ->
        Status.broadcast(%{request_id: "r1"}, :retrieving, "Searching…", FakeNodeRouter)
      end
    end
  end

  describe "broadcast/4 with nil" do
    test "returns nil and does not crash" do
      assert nil == Status.broadcast(nil, :validating, "x", FakeNodeRouter)
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

      assert %{
               session_id: "s1",
               request_id: "r1",
               provider: :web,
               channel_id: "bo",
               thread_id: nil,
               node_router: FakeNodeRouter
             } =
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

      assert %{
               session_id: nil,
               request_id: "r1",
               provider: :web,
               channel_id: "bo",
               thread_id: nil,
               node_router: Zaq.NodeRouter
             } = Status.context_from_event(missing_session)

      assert Status.context_from_event(missing_request) == nil
    end
  end
end
