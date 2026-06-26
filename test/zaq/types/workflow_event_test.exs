defmodule Zaq.Types.WorkflowEventTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Types.WorkflowEvent

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @trace_id "550e8400-e29b-41d4-a716-446655440000"

  defp sample_event do
    %Event{
      request: %{type: "email"},
      assigns: %{trigger_type: :manual, input: %{mailbox: "INBOX"}},
      trace_id: @trace_id,
      next_hop: nil,
      hops: []
    }
  end

  describe "cast/1" do
    test "casts a %Zaq.Event{} struct as-is" do
      event = sample_event()
      assert {:ok, ^event} = WorkflowEvent.cast(event)
    end

    test "casts a string-key map into a %Zaq.Event{}" do
      map = %{
        "request" => %{"type" => "email"},
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => @trace_id,
        "hops" => [],
        "next_hop" => nil
      }

      assert {:ok, %Event{} = event} = WorkflowEvent.cast(map)
      assert event.trace_id == @trace_id
      assert event.assigns == %{"trigger_type" => "manual"}
    end

    test "casts an atom-key map" do
      map = %{
        request: nil,
        assigns: %{trigger_type: :scheduler},
        trace_id: @trace_id,
        hops: [],
        next_hop: nil
      }

      assert {:ok, %Event{} = event} = WorkflowEvent.cast(map)
      assert event.trace_id == @trace_id
    end

    test "returns :error for nil" do
      assert :error = WorkflowEvent.cast(nil)
    end

    test "returns :error for non-map" do
      assert :error = WorkflowEvent.cast("bad")
      assert :error = WorkflowEvent.cast(42)
    end
  end

  describe "dump/1" do
    test "dumps a %Zaq.Event{} to a plain serializable map" do
      event = sample_event()
      assert {:ok, map} = WorkflowEvent.dump(event)
      assert is_map(map)
      assert map["trace_id"] == @trace_id
      assert map["assigns"] == %{trigger_type: :manual, input: %{mailbox: "INBOX"}}
    end

    test "dumps an already-plain map through unchanged" do
      plain = %{
        "trace_id" => @trace_id,
        "request" => nil,
        "assigns" => %{},
        "hops" => [],
        "next_hop" => nil
      }

      assert {:ok, ^plain} = WorkflowEvent.dump(plain)
    end

    test "dumps struct payloads to JSON-encodable maps" do
      incoming = %Incoming{
        content: "@zaq Yo",
        channel_id: "channel-1",
        author_id: "user-1",
        author_name: "alice",
        message_id: "message-1",
        provider: :mattermost,
        metadata: %{transport: "websocket"},
        content_filter: []
      }

      event = %Event{sample_event() | request: incoming, actor: %{provider: :mattermost}}

      assert {:ok, map} = WorkflowEvent.dump(event)
      assert map["request"].content == "@zaq Yo"
      assert map["request"].provider == :mattermost
      assert map["request"].metadata.transport == "websocket"
      assert map["actor"].provider == :mattermost
      assert Jason.encode!(map)
    end

    test "returns :error for nil" do
      assert :error = WorkflowEvent.dump(nil)
    end
  end

  describe "load/1" do
    test "loads a string-key map from DB into %Zaq.Event{}" do
      db_map = %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => @trace_id,
        "hops" => [],
        "next_hop" => nil
      }

      assert {:ok, %Event{} = event} = WorkflowEvent.load(db_map)
      assert event.trace_id == @trace_id
    end

    test "round-trip: dump then load preserves trace_id and assigns" do
      event = sample_event()
      {:ok, dumped} = WorkflowEvent.dump(event)
      {:ok, loaded} = WorkflowEvent.load(dumped)

      assert loaded.trace_id == event.trace_id
      assert loaded.assigns == %{trigger_type: :manual, input: %{mailbox: "INBOX"}}
    end

    test "returns :error for nil" do
      assert :error = WorkflowEvent.load(nil)
    end
  end

  describe "equal?/2" do
    test "two events with the same trace_id are equal" do
      e1 = %Event{request: nil, assigns: %{}, trace_id: @trace_id, next_hop: nil, hops: []}

      e2 = %Event{
        request: %{extra: true},
        assigns: %{other: 1},
        trace_id: @trace_id,
        next_hop: nil,
        hops: []
      }

      assert WorkflowEvent.equal?(e1, e2)
    end

    test "two events with different trace_ids are not equal" do
      e1 = %Event{request: nil, assigns: %{}, trace_id: @trace_id, next_hop: nil, hops: []}
      e2 = %Event{request: nil, assigns: %{}, trace_id: "other-id", next_hop: nil, hops: []}
      refute WorkflowEvent.equal?(e1, e2)
    end
  end

  describe "WorkflowRun integration" do
    test "source_event round-trips through the DB as a %Zaq.Event{}" do
      alias Zaq.Engine.Workflows
      alias Zaq.Engine.Workflows.WorkflowRun

      steps = %{
        "nodes" => [],
        "edges" => []
      }

      {:ok, workflow} =
        Workflows.create_workflow(%{name: "Test", status: "draft", steps: steps})

      event = sample_event()
      {:ok, run} = Workflows.create_run(workflow, event)

      assert %WorkflowRun{source_event: %Event{} = loaded} = Workflows.get_run!(run.id)
      assert loaded.trace_id == @trace_id
    end

    test "source_event with Incoming request persists through JSONB" do
      alias Zaq.Engine.Workflows
      alias Zaq.Engine.Workflows.WorkflowRun

      steps = %{
        "nodes" => [],
        "edges" => []
      }

      {:ok, workflow} =
        Workflows.create_workflow(%{name: "Incoming Test", status: "draft", steps: steps})

      incoming = %Incoming{
        content: "@zaq Yo",
        channel_id: "channel-1",
        author_id: "user-1",
        author_name: "alice",
        message_id: "message-1",
        provider: :mattermost,
        metadata: %{transport: "websocket"},
        content_filter: []
      }

      event = %Event{sample_event() | request: incoming}

      assert {:ok, run} = Workflows.create_run(workflow, event)
      assert %WorkflowRun{source_event: %Event{} = loaded} = Workflows.get_run!(run.id)
      assert loaded.request["content"] == "@zaq Yo"
      assert loaded.request["provider"] == "mattermost"
    end
  end
end
