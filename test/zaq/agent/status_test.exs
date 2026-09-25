defmodule Zaq.Agent.StatusTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Status
  alias Zaq.Channels.Events, as: ChannelEvents
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  # Executes the event's request locally — avoids real RPC in unit tests.
  defmodule FakeNodeRouter do
    alias Zaq.Engine.Messages.Outgoing
    alias Zaq.Event

    def dispatch(%Event{opts: opts, request: request} = event) do
      if opts[:action] == :upsert_message and match?(%Outgoing{}, request) do
        metadata = if is_map(request.metadata), do: request.metadata, else: %{}
        session_id = metadata[:session_id]
        request_id = metadata[:request_id]
        message = request.body
        stage = get_in(metadata, [:intent_meta, :stage]) || :answering

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

  defmodule FakeNodeRouterIntegerMessageId do
    alias Zaq.Event

    def dispatch(%Event{opts: opts, request: request} = event) do
      if opts[:action] == :upsert_message do
        %{event | response: {:ok, %{action: :updated, message_id: 52}}}
      else
        metadata = if is_map(request.metadata), do: request.metadata, else: %{}
        %{event | response: {:ok, %{message_id: metadata[:request_id]}}}
      end
    end
  end

  defmodule RecordingNodeRouter do
    def dispatch(%Zaq.Event{} = event) do
      send(self(), {:upsert_event, event})
      %{event | response: {:ok, %{action: :updated, message_id: "mattermost-post"}}}
    end
  end

  defmodule BlockingNodeRouter do
    def dispatch(%Zaq.Event{request: %Zaq.Engine.Messages.Outgoing{} = outgoing} = event) do
      send(outgoing.metadata.session_id, {:channel_edit_started, outgoing.body, self()})

      if outgoing.body == "5 in Arabic is ٥" do
        receive do
          :release_partial_edit -> :ok
        end
      end

      send(outgoing.metadata.session_id, {:channel_edit_completed, outgoing.body})
      %{event | response: {:ok, %{action: :updated, message_id: "mattermost-post"}}}
    end
  end

  describe "broadcast/4 with %Incoming{}" do
    test "status upserts use the ingress-stamped connector rather than metadata" do
      context = %Zaq.Engine.Messages.Incoming.RoutingContext{channel_config_id: 42}

      incoming = %Incoming{
        content: "hello",
        provider: :mattermost,
        channel_id: "room-1",
        routing_context: context,
        metadata: %{request_id: "question-1", channel_config_id: 99}
      }

      Status.broadcast(incoming, :answering, "Working", RecordingNodeRouter)
      assert_receive {:upsert_event, %Event{request: outgoing}}
      assert outgoing.routing_context == context
    end

    test "partial edits await completion before the final answer can be delivered" do
      incoming = %Incoming{
        content: "How do you say five?",
        provider: :mattermost,
        channel_id: "room-1",
        metadata: %{request_id: "question-1", status_message_id: "mattermost-post"}
      }

      assert %Incoming{} =
               Status.broadcast(incoming, :answering, "5 in Arabic is ٥", RecordingNodeRouter,
                 update_intent: :streaming
               )

      assert_receive {:upsert_event, %Event{request: request, next_hop: %{type: :sync}}}
      assert request.body == "5 in Arabic is ٥"
      assert request.metadata.status_message_id == "mattermost-post"
    end

    test "delayed partial cannot overwrite a completed Arabic answer" do
      full = "5 in Arabic is ٥ — pronounced khamsa (خمسة)."

      incoming = %Incoming{
        content: "How do you say five?",
        provider: :mattermost,
        channel_id: "room-1",
        metadata: %{
          session_id: self(),
          request_id: "question-1",
          status_message_id: "mattermost-post"
        }
      }

      task =
        Task.async(fn ->
          updated =
            Status.broadcast(incoming, :answering, "5 in Arabic is ٥", BlockingNodeRouter,
              update_intent: :streaming
            )

          ChannelEvents.build_and_dispatch_deliver_outgoing_event(
            %Outgoing{
              provider: :mattermost,
              channel_id: "room-1",
              body: full,
              metadata: updated.metadata
            },
            node_router: BlockingNodeRouter
          )
        end)

      assert_receive {:channel_edit_started, "5 in Arabic is ٥", partial_pid}
      refute_receive {:channel_edit_started, ^full, _}, 40
      send(partial_pid, :release_partial_edit)
      assert_receive {:channel_edit_completed, "5 in Arabic is ٥"}
      assert_receive {:channel_edit_started, ^full, _}
      assert_receive {:channel_edit_completed, ^full}
      assert %Event{} = Task.await(task)
    end

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

    test "stores integer status_message_id returned by upsert response" do
      incoming = %Incoming{
        content: "hi",
        channel_id: "bo",
        provider: :web,
        metadata: %{session_id: "s1", request_id: "r1"}
      }

      assert %Incoming{metadata: %{status_message_id: 52}} =
               Status.broadcast(incoming, :validating, "Checking", FakeNodeRouterIntegerMessageId)
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

    test "accepts integer request_id from incoming message_id fallback" do
      event =
        Event.new(
          %Incoming{
            content: "hi",
            channel_id: "bo",
            provider: :web,
            message_id: 52,
            metadata: %{session_id: "s1"}
          },
          :agent,
          opts: [node_router: FakeNodeRouter]
        )

      assert %{
               session_id: "s1",
               request_id: 52,
               provider: :web,
               channel_id: "bo",
               thread_id: nil,
               node_router: FakeNodeRouter
             } = Status.context_from_event(event)
    end

    test "falls back to incoming message_id when metadata request_id is blank" do
      event =
        Event.new(
          %Incoming{
            content: "hi",
            channel_id: "bo",
            provider: :web,
            message_id: "msg-52",
            metadata: %{session_id: "s1", request_id: ""}
          },
          :agent,
          opts: [node_router: FakeNodeRouter]
        )

      assert %{
               session_id: "s1",
               request_id: "msg-52",
               provider: :web,
               channel_id: "bo",
               thread_id: nil,
               node_router: FakeNodeRouter
             } = Status.context_from_event(event)
    end
  end
end
