defmodule Zaq.Engine.EventRegistryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.EventRegistry
  alias Zaq.Engine.Workflows
  alias Zaq.Event

  @pubsub Zaq.PubSub
  @topic "node_router:events"

  # Helper: broadcast an event to the topic as NodeRouter would.
  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:node_router_event, event})
  end

  # Helper: build a minimal Event struct (bypasses NodeRouter).
  defp build_event(name) do
    %Event{
      request: %{},
      next_hop: nil,
      name: name,
      trace_id: Ecto.UUID.generate()
    }
  end

  # Returns the events sub-map from the GenServer state.
  defp get_events(pid) do
    :sys.get_state(pid).events
  end

  # Starts a fresh EventRegistry with injected deps for isolation.
  # Uses a unique name per test to avoid name conflicts with any running instance.
  defp start_registry(opts \\ []) do
    name = :"event_registry_#{System.unique_integer([:positive])}"
    start_supervised!({EventRegistry, Keyword.put(opts, :name, name)})
  end

  describe "init/1 — loads trigger state from DB" do
    test "starts with trigger event_names marked as true in state" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "order_placed", enabled: true})

      pid = start_registry()

      assert Map.get(get_events(pid), "order_placed") == true
    end

    test "starts with empty events map when no triggers exist" do
      pid = start_registry()
      assert get_events(pid) == %{}
    end

    test "excludes disabled triggers from initial state" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "disabled_event", enabled: false})

      pid = start_registry()
      refute Map.has_key?(get_events(pid), "disabled_event")
    end
  end

  describe "handle_info/2 — nil name events" do
    test "ignores events with name: nil — state unchanged" do
      pid = start_registry()
      initial_events = get_events(pid)

      broadcast(build_event(nil))
      # Synchronize — get_state/1 sends a sys message which queues after the broadcast
      :sys.get_state(pid)

      assert get_events(pid) == initial_events
    end
  end

  describe "handle_info/2 — unknown event names" do
    test "stores unseen event name as false" do
      pid = start_registry()

      broadcast(build_event(:some_unknown_event))
      :sys.get_state(pid)

      assert Map.get(get_events(pid), "some_unknown_event") == false
    end

    test "does not update state to true for repeated false events" do
      pid = start_registry()

      broadcast(build_event(:another_unknown))
      :sys.get_state(pid)
      broadcast(build_event(:another_unknown))
      :sys.get_state(pid)

      assert Map.get(get_events(pid), "another_unknown") == false
    end
  end

  describe "handle_info/2 — known trigger events" do
    test "fires TriggerNode when a known trigger event arrives" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "invoice_created", enabled: true})

      test_pid = self()

      trigger_node_fn = fn event_name, _event ->
        send(test_pid, {:trigger_node_fired, event_name})
        :ok
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)

      broadcast(build_event(:invoice_created))
      :sys.get_state(pid)

      assert_receive {:trigger_node_fired, "invoice_created"}
    end

    test "does not change events map after firing a known trigger" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "payment_received", enabled: true})

      pid = start_registry(trigger_node_fn: fn _name, _event -> :ok end)

      initial_events = get_events(pid)
      broadcast(build_event(:payment_received))
      :sys.get_state(pid)

      assert get_events(pid) == initial_events
    end

    test "does not fire TriggerNode for events stored as false" do
      test_pid = self()

      trigger_node_fn = fn event_name, _event ->
        send(test_pid, {:trigger_node_fired, event_name})
        :ok
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)

      # unknown event → stored as false
      broadcast(build_event(:not_a_trigger))
      :sys.get_state(pid)

      # broadcast again — should NOT fire TriggerNode
      broadcast(build_event(:not_a_trigger))
      :sys.get_state(pid)

      refute_receive {:trigger_node_fired, "not_a_trigger"}
    end
  end
end
