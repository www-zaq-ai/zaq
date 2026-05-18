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
    Event.new(%{}, :engine, name: name)
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

  describe "list_events/2" do
    test "returns empty map when no events in state" do
      pid = start_registry()
      assert %{} = EventRegistry.list_events([], pid)
    end

    test "returns all events (both true and false) when no filter" do
      {:ok, _trigger} = Workflows.create_trigger(%{event_name: "trigger_evt", enabled: true})
      pid = start_registry()

      broadcast(build_event(:unknown_evt))
      :sys.get_state(pid)

      result = EventRegistry.list_events([], pid)
      assert map_size(result) == 2
    end

    test "returns only trigger events when is_trigger: true" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "active_trigger", enabled: true})
      pid = start_registry()

      broadcast(build_event(:not_a_trigger_evt))
      :sys.get_state(pid)

      result = EventRegistry.list_events([is_trigger: true], pid)
      assert Enum.all?(result, fn {_k, v} -> v == true end)
      assert Map.has_key?(result, "active_trigger")
    end

    test "returns only non-trigger events when is_trigger: false" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "trigger_only", enabled: true})
      pid = start_registry()

      broadcast(build_event(:seen_but_not_trigger))
      :sys.get_state(pid)

      result = EventRegistry.list_events([is_trigger: false], pid)
      assert Enum.all?(result, fn {_k, v} -> v == false end)
      assert Map.has_key?(result, "seen_but_not_trigger")
      refute Map.has_key?(result, "trigger_only")
    end

    test "keys are strings and values are booleans" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "named_trigger", enabled: true})
      pid = start_registry()

      result = EventRegistry.list_events([], pid)
      assert Enum.all?(result, fn {k, v} -> is_binary(k) and is_boolean(v) end)
    end
  end

  describe "deactivate/2" do
    test "sets a known trigger event to false in state" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "order_placed", enabled: true})
      pid = start_registry()

      assert Map.get(get_events(pid), "order_placed") == true
      :ok = EventRegistry.deactivate("order_placed", pid)
      assert Map.get(get_events(pid), "order_placed") == false
    end

    test "stores unknown event name as false (creates the entry)" do
      pid = start_registry()
      refute Map.has_key?(get_events(pid), "brand_new_event")

      :ok = EventRegistry.deactivate("brand_new_event", pid)
      assert Map.get(get_events(pid), "brand_new_event") == false
    end

    test "after deactivate, incoming node_router_event does NOT fire TriggerNode" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "ship_order", enabled: true})
      test_pid = self()

      trigger_node_fn = fn event_name, _event ->
        send(test_pid, {:triggered, event_name})
        :ok
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)
      :ok = EventRegistry.deactivate("ship_order", pid)

      broadcast(build_event(:ship_order))
      :sys.get_state(pid)

      refute_receive {:triggered, "ship_order"}
    end
  end

  describe "activate/2" do
    test "sets a false event to true in state" do
      pid = start_registry()
      :ok = EventRegistry.deactivate("my_event", pid)
      assert Map.get(get_events(pid), "my_event") == false

      :ok = EventRegistry.activate("my_event", pid)
      assert Map.get(get_events(pid), "my_event") == true
    end

    test "after activate, incoming node_router_event DOES fire TriggerNode" do
      pid_test = self()

      trigger_node_fn = fn event_name, _event ->
        send(pid_test, {:triggered, event_name})
        :ok
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)

      # Seed the event as false first
      :ok = EventRegistry.deactivate("re_enable_evt", pid)
      :ok = EventRegistry.activate("re_enable_evt", pid)

      broadcast(build_event(:re_enable_evt))
      :sys.get_state(pid)

      assert_receive {:triggered, "re_enable_evt"}
    end

    test "activating an already-true event keeps it true" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "already_true", enabled: true})
      pid = start_registry()

      assert Map.get(get_events(pid), "already_true") == true
      :ok = EventRegistry.activate("already_true", pid)
      assert Map.get(get_events(pid), "already_true") == true
    end
  end

  describe "Workflows.update_trigger/3 — registry sync integration" do
    # The global EventRegistry singleton may or may not be running.
    # sync_registry/1 uses Process.whereis(EventRegistry) — so we call
    # activate/deactivate directly on the default server to verify the
    # wiring without fighting process registration.

    test "disabling a trigger via Workflows.update_trigger/3 returns enabled: false" do
      {:ok, trigger} = Workflows.create_trigger(%{event_name: "sync_deactivate", enabled: true})
      assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: false})
      assert updated.enabled == false
    end

    test "enabling a trigger via Workflows.update_trigger/3 returns enabled: true" do
      {:ok, trigger} = Workflows.create_trigger(%{event_name: "sync_activate", enabled: false})
      assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: true})
      assert updated.enabled == true
    end

    test "sync_registry is skipped gracefully when EventRegistry singleton is not registered" do
      # Verify by calling update_trigger when the global EventRegistry is not running.
      # We stop the singleton if it is alive, run the update, then verify no crash.
      existing = Process.whereis(EventRegistry)
      if existing, do: Process.unregister(EventRegistry)

      {:ok, trigger} = Workflows.create_trigger(%{event_name: "no_registry_event", enabled: true})

      try do
        assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: false})
        assert updated.enabled == false
      after
        # Re-register the original pid if we unregistered it
        if existing && Process.alive?(existing) do
          Process.register(existing, EventRegistry)
        end
      end
    end
  end
end
