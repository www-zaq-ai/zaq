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

  # Helper: build a named Event struct (bypasses NodeRouter).
  defp build_event(name) do
    Event.new(%{}, :engine, name: name)
  end

  # Helper: build an Event with opts[:action] and no name (as NodeRouter dispatch does).
  defp build_action_event(action) do
    Event.new(%{}, :engine, opts: [action: action])
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

  # Temporarily registers an isolated EventRegistry under the global name so
  # sync_registry/1 (which uses Process.whereis(EventRegistry)) hits our test
  # process. Injects a no-op trigger_node_fn by default to prevent real DB calls.
  defp with_registry_as_singleton(fun), do: with_registry_as_singleton([], fun)

  defp with_registry_as_singleton(opts, fun) do
    existing = Process.whereis(EventRegistry)
    if existing, do: Process.unregister(EventRegistry)

    trigger_fn = Keyword.get(opts, :trigger_node_fn, fn _n, _e -> :ok end)

    {:ok, pid} =
      start_supervised(
        {EventRegistry, [name: nil, trigger_node_fn: trigger_fn]},
        id: :singleton_event_registry
      )

    Process.register(pid, EventRegistry)

    try do
      fun.(pid)
    after
      if Process.alive?(pid), do: Process.unregister(EventRegistry)
      if existing && Process.alive?(existing), do: Process.register(existing, EventRegistry)
    end
  end

  describe "init/1 — loads trigger state from DB" do
    test "starts with trigger event_names marked as true in state" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "engine:order_placed", enabled: true})

      pid = start_registry()

      assert Map.get(get_events(pid), "engine:order_placed") == true
    end

    test "starts with empty events map when no triggers exist" do
      pid = start_registry()
      assert get_events(pid) == %{}
    end

    test "excludes disabled triggers from initial state" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "engine:disabled_event", enabled: false})

      pid = start_registry()
      refute Map.has_key?(get_events(pid), "engine:disabled_event")
    end
  end

  describe "handle_info/2 — ignored events (no name, no action)" do
    test "ignores events with name: nil and no opts[:action] — state unchanged" do
      pid = start_registry()
      initial_events = get_events(pid)

      broadcast(build_event(nil))
      # Synchronize — get_state/1 sends a sys message which queues after the broadcast
      :sys.get_state(pid)

      assert get_events(pid) == initial_events
    end
  end

  describe "handle_info/2 — opts[:action] fallback" do
    test "stores unseen opts[:action] as false when no name is set" do
      pid = start_registry()

      broadcast(build_action_event(:persist_from_incoming))
      :sys.get_state(pid)

      assert Map.get(get_events(pid), "engine:persist_from_incoming") == false
    end

    test "fires TriggerNode when opts[:action] matches a known trigger event_name" do
      {:ok, _} =
        Workflows.create_trigger(%{event_name: "engine:persist_from_incoming", enabled: true})

      test_pid = self()

      trigger_node_fn = fn event_name, _event ->
        send(test_pid, {:trigger_node_fired, event_name})
        :ok
      end

      with_registry_as_singleton([trigger_node_fn: trigger_node_fn], fn pid ->
        broadcast(build_action_event(:persist_from_incoming))
        :sys.get_state(pid)

        assert_receive {:trigger_node_fired, "engine:persist_from_incoming"}
      end)
    end

    test "name takes precedence over opts[:action] when both are set" do
      pid = start_registry()

      event = Event.new(%{}, :engine, name: :explicit_name, opts: [action: :some_action])
      broadcast(event)
      :sys.get_state(pid)

      assert Map.get(get_events(pid), "engine:explicit_name") == false
      refute Map.has_key?(get_events(pid), "engine:some_action")
    end
  end

  describe "handle_info/2 — unknown event names" do
    test "stores unseen event name as false" do
      pid = start_registry()

      broadcast(build_event(:some_unknown_event))
      :sys.get_state(pid)

      assert Map.get(get_events(pid), "engine:some_unknown_event") == false
    end

    test "does not update state to true for repeated false events" do
      pid = start_registry()

      broadcast(build_event(:another_unknown))
      :sys.get_state(pid)
      broadcast(build_event(:another_unknown))
      :sys.get_state(pid)

      assert Map.get(get_events(pid), "engine:another_unknown") == false
    end
  end

  describe "handle_info/2 — known trigger events" do
    test "fires TriggerNode when a known trigger event arrives" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "engine:invoice_created", enabled: true})

      test_pid = self()

      trigger_node_fn = fn event_name, _event ->
        send(test_pid, {:trigger_node_fired, event_name})
        :ok
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)

      broadcast(build_event(:invoice_created))
      :sys.get_state(pid)

      assert_receive {:trigger_node_fired, "engine:invoice_created"}
    end

    test "does not change events map after firing a known trigger" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "engine:payment_received", enabled: true})

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

      refute_receive {:trigger_node_fired, "engine:not_a_trigger"}
    end
  end

  describe "fire_or_register — task fault isolation" do
    test "EventRegistry process survives a raising fire_fn" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "engine:fault_test", enabled: true})

      trigger_node_fn = fn _name, _event -> raise "simulated failure" end
      pid = start_registry(trigger_node_fn: trigger_node_fn)

      broadcast(build_event(:fault_test))
      :sys.get_state(pid)
      Process.sleep(20)

      assert Process.alive?(pid)
    end

    test "EventRegistry continues firing after a previous task failure" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "engine:resilience_test", enabled: true})
      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      trigger_node_fn = fn name, _event ->
        count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if count == 0, do: raise("first attempt fails"), else: send(test_pid, {:fired, name})
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)

      broadcast(build_event(:resilience_test))
      :sys.get_state(pid)
      Process.sleep(20)

      broadcast(build_event(:resilience_test))
      :sys.get_state(pid)

      assert_receive {:fired, "engine:resilience_test"}, 500
      assert Process.alive?(pid)
    end
  end

  describe "list_events/2" do
    test "returns empty map when no events in state" do
      pid = start_registry()
      assert %{} = EventRegistry.list_events([], pid)
    end

    test "returns all events (both true and false) when no filter" do
      {:ok, _trigger} =
        Workflows.create_trigger(%{event_name: "engine:trigger_evt", enabled: true})

      pid = start_registry()

      broadcast(build_event(:unknown_evt))
      :sys.get_state(pid)

      result = EventRegistry.list_events([], pid)
      assert map_size(result) == 2
    end

    test "returns only trigger events when is_trigger: true" do
      {:ok, _} =
        Workflows.create_trigger(%{event_name: "engine:active_trigger", enabled: true})

      pid = start_registry()

      broadcast(build_event(:not_a_trigger_evt))
      :sys.get_state(pid)

      result = EventRegistry.list_events([is_trigger: true], pid)
      assert Enum.all?(result, fn {_k, v} -> v == true end)
      assert Map.has_key?(result, "engine:active_trigger")
    end

    test "returns only non-trigger events when is_trigger: false" do
      {:ok, _} =
        Workflows.create_trigger(%{event_name: "engine:trigger_only", enabled: true})

      pid = start_registry()

      broadcast(build_event(:seen_but_not_trigger))
      :sys.get_state(pid)

      result = EventRegistry.list_events([is_trigger: false], pid)
      assert Enum.all?(result, fn {_k, v} -> v == false end)
      assert Map.has_key?(result, "engine:seen_but_not_trigger")
      refute Map.has_key?(result, "engine:trigger_only")
    end

    test "keys are strings and values are booleans" do
      {:ok, _} =
        Workflows.create_trigger(%{event_name: "engine:named_trigger", enabled: true})

      pid = start_registry()

      result = EventRegistry.list_events([], pid)
      assert Enum.all?(result, fn {k, v} -> is_binary(k) and is_boolean(v) end)
    end
  end

  describe "deactivate/2" do
    test "sets a known trigger event to false in state" do
      {:ok, _} =
        Workflows.create_trigger(%{event_name: "engine:order_placed", enabled: true})

      pid = start_registry()

      assert Map.get(get_events(pid), "engine:order_placed") == true
      :ok = EventRegistry.deactivate("engine:order_placed", pid)
      assert Map.get(get_events(pid), "engine:order_placed") == false
    end

    test "stores unknown event name as false (creates the entry)" do
      pid = start_registry()
      refute Map.has_key?(get_events(pid), "engine:brand_new_event")

      :ok = EventRegistry.deactivate("engine:brand_new_event", pid)
      assert Map.get(get_events(pid), "engine:brand_new_event") == false
    end

    test "after deactivate, incoming node_router_event does NOT fire TriggerNode" do
      {:ok, _} =
        Workflows.create_trigger(%{event_name: "engine:ship_order", enabled: true})

      test_pid = self()

      trigger_node_fn = fn event_name, _event ->
        send(test_pid, {:triggered, event_name})
        :ok
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)
      :ok = EventRegistry.deactivate("engine:ship_order", pid)

      broadcast(build_event(:ship_order))
      :sys.get_state(pid)

      refute_receive {:triggered, "engine:ship_order"}
    end
  end

  describe "activate/2" do
    test "sets a false event to true in state" do
      pid = start_registry()
      :ok = EventRegistry.deactivate("engine:my_event", pid)
      assert Map.get(get_events(pid), "engine:my_event") == false

      :ok = EventRegistry.activate("engine:my_event", pid)
      assert Map.get(get_events(pid), "engine:my_event") == true
    end

    test "after activate, incoming node_router_event DOES fire TriggerNode" do
      pid_test = self()

      trigger_node_fn = fn event_name, _event ->
        send(pid_test, {:triggered, event_name})
        :ok
      end

      pid = start_registry(trigger_node_fn: trigger_node_fn)

      # Seed the event as false first
      :ok = EventRegistry.deactivate("engine:re_enable_evt", pid)
      :ok = EventRegistry.activate("engine:re_enable_evt", pid)

      broadcast(build_event(:re_enable_evt))
      :sys.get_state(pid)

      assert_receive {:triggered, "engine:re_enable_evt"}
    end

    test "activating an already-true event keeps it true" do
      {:ok, _} =
        Workflows.create_trigger(%{event_name: "engine:already_true", enabled: true})

      pid = start_registry()

      assert Map.get(get_events(pid), "engine:already_true") == true
      :ok = EventRegistry.activate("engine:already_true", pid)
      assert Map.get(get_events(pid), "engine:already_true") == true
    end
  end

  describe "Workflows.create_trigger/2 — registry sync integration" do
    test "creating an enabled trigger immediately marks it true in the running registry" do
      with_registry_as_singleton(fn pid ->
        refute Map.has_key?(get_events(pid), "engine:get_person")

        {:ok, _} =
          Workflows.create_trigger(%{event_name: "engine:get_person", enabled: true})

        assert Map.get(get_events(pid), "engine:get_person") == true
      end)
    end

    test "creating a disabled trigger marks it false in the running registry" do
      with_registry_as_singleton(fn pid ->
        {:ok, _} =
          Workflows.create_trigger(%{event_name: "engine:get_person", enabled: false})

        assert Map.get(get_events(pid), "engine:get_person") == false
      end)
    end

    test "on restart, registry loads created enabled trigger as true from DB" do
      with_registry_as_singleton(fn _pid ->
        {:ok, _} =
          Workflows.create_trigger(%{event_name: "engine:get_person", enabled: true})
      end)

      pid = start_registry()
      assert Map.get(get_events(pid), "engine:get_person") == true
    end

    test "create_trigger sync is skipped gracefully when EventRegistry is not running" do
      existing = Process.whereis(EventRegistry)
      if existing, do: Process.unregister(EventRegistry)

      try do
        assert {:ok, trigger} =
                 Workflows.create_trigger(%{
                   event_name: "engine:no_registry_create",
                   enabled: true
                 })

        assert trigger.event_name == "engine:no_registry_create"
      after
        if existing && Process.alive?(existing), do: Process.register(existing, EventRegistry)
      end
    end
  end

  describe "Workflows.update_trigger/3 — registry sync integration" do
    test "disabling a trigger via Workflows.update_trigger/3 returns enabled: false" do
      with_registry_as_singleton(fn _pid ->
        {:ok, trigger} =
          Workflows.create_trigger(%{event_name: "engine:sync_deactivate", enabled: true})

        assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: false})
        assert updated.enabled == false
      end)
    end

    test "enabling a trigger via Workflows.update_trigger/3 returns enabled: true" do
      with_registry_as_singleton(fn _pid ->
        {:ok, trigger} =
          Workflows.create_trigger(%{event_name: "engine:sync_activate", enabled: false})

        assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: true})
        assert updated.enabled == true
      end)
    end

    test "sync_registry is skipped gracefully when EventRegistry singleton is not registered" do
      existing = Process.whereis(EventRegistry)
      if existing, do: Process.unregister(EventRegistry)

      {:ok, trigger} =
        Workflows.create_trigger(%{event_name: "engine:no_registry_event", enabled: true})

      try do
        assert {:ok, updated} = Workflows.update_trigger(trigger, %{enabled: false})
        assert updated.enabled == false
      after
        if existing && Process.alive?(existing), do: Process.register(existing, EventRegistry)
      end
    end
  end
end
