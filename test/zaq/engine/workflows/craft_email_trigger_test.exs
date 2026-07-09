defmodule Zaq.Engine.Workflows.CraftEmailTriggerTest do
  @moduledoc """
  Validates — end to end, without guessing — whether a `craft_email` event
  dispatched by `GenerateCompanyContext` can trigger `SendLeadsEmail`.

  Each test isolates one link in the chain:

    DispatchEvent (name: "craft_email", dest: :engine)
      → NodeRouter broadcast
      → EventRegistry derives key "engine:craft_email" and fires
      → TriggerNode.fire creates a SendLeadsEmail run

  so a failure points at exactly one link instead of "it doesn't work".
  """
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Engine.{EventRegistry, TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.UseCases.SendLeadsEmail
  alias Zaq.Event

  @pubsub Zaq.PubSub
  @topic "node_router:events"

  setup :verify_on_exit!

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Event{} = event -> %{event | response: nil} end)
    :ok
  end

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(@pubsub, @topic, {:node_router_event, event})

  # Mirrors the isolation helper from EventRegistryTest: run an isolated registry
  # under the global name so it loads trigger state from the (sandboxed) DB.
  defp with_registry_as_singleton(opts, fun) do
    existing = Process.whereis(EventRegistry)
    if existing, do: Process.unregister(EventRegistry)

    trigger_fn = Keyword.get(opts, :trigger_node_fn, fn _n, _e -> :ok end)

    {:ok, pid} =
      start_supervised({EventRegistry, [name: nil, trigger_node_fn: trigger_fn]},
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

  describe "link 1: SendLeadsEmail.create/1 registers the engine:craft_email trigger" do
    test "the persisted trigger event_name is normalized to engine:craft_email" do
      assert {:ok, workflow} = SendLeadsEmail.create()

      [trigger] = Workflows.list_triggers_for_workflow(workflow.id)
      assert trigger.event_name == "engine:craft_email"
      assert trigger.enabled

      # And it is exposed to EventRegistry's loader.
      assert "engine:craft_email" in Workflows.list_trigger_event_names()
    end
  end

  describe "link 2: DispatchEvent emits the right event" do
    test "dispatches name=craft_email to destination :engine (default)" do
      test_pid = self()

      stub(Zaq.NodeRouterMock, :dispatch, fn %Event{} = event ->
        send(test_pid, {:dispatched, event})
        %{event | response: nil}
      end)

      # Exactly the params GenerateCompanyContext's craft_email node carries, with
      # a scalar (string) input like the real mapping produces.
      params = %{event_name: "craft_email", machine: true, input: "## Company Summary"}

      assert {:ok, %{dispatched: _}} =
               DispatchEvent.run(params, %{node_router: Zaq.NodeRouterMock})

      assert_received {:dispatched,
                       %Event{name: "craft_email", next_hop: %{destination: :engine}}}
    end
  end

  describe "link 3: EventRegistry matches the dispatched event and fires" do
    test "a craft_email event fires the engine:craft_email trigger (scalar request too)" do
      {:ok, _} = Workflows.create_trigger(%{event_name: "craft_email", enabled: true})

      test_pid = self()
      fire_fn = fn name, _event -> send(test_pid, {:fired, name}) end

      with_registry_as_singleton([trigger_node_fn: fire_fn], fn pid ->
        # Built exactly as DispatchEvent builds it — scalar string request included.
        event = Event.new("## Company Summary", :engine, type: :async, name: "craft_email")
        broadcast(event)
        # Synchronize the GenServer mailbox after the broadcast.
        :sys.get_state(pid)

        assert_receive {:fired, "engine:craft_email"}, 1000
      end)
    end

    test "does NOT fire when no engine:craft_email trigger is registered (the prod failure mode)" do
      # No trigger created → registry has no engine:craft_email → nothing fires.
      test_pid = self()
      fire_fn = fn name, _event -> send(test_pid, {:fired, name}) end

      with_registry_as_singleton([trigger_node_fn: fire_fn], fn pid ->
        event = Event.new("## Company Summary", :engine, type: :async, name: "craft_email")
        broadcast(event)
        :sys.get_state(pid)

        refute_receive {:fired, _}, 300
      end)
    end
  end

  describe "link 4: TriggerNode.fire builds the source event and creates a run" do
    test "a scalar craft_email payload no longer crashes TriggerNode — a run is created" do
      assert {:ok, workflow} = SendLeadsEmail.create()

      # craft_email dispatches a SCALAR request, because GenerateCompanyContext
      # maps its `input` to `build_context_document.result` (a string). This used
      # to crash machine_event?/1 with BadMapError before create_and_start_run ran;
      # now a non-map request is simply "not a machine event" and the run starts.
      scalar_event = %Event{
        request: "## Company Summary",
        next_hop: nil,
        name: :craft_email,
        trace_id: Ecto.UUID.generate(),
        assigns: %{}
      }

      :ok = TriggerNode.fire("engine:craft_email", scalar_event)

      assert [_run] = Workflows.list_runs(workflow.id),
             "a scalar payload must not crash TriggerNode — the run should be created"
    end

    test "a MAP craft_email payload builds the source event and creates a run" do
      assert {:ok, workflow} = SendLeadsEmail.create()

      # The same trigger, but with a map request (what a map `input` would produce):
      # build_input/machine_event? both work, so the run is created.
      map_event = %Event{
        request: %{"content" => "## Company Summary", "machine" => true},
        next_hop: nil,
        name: :craft_email,
        trace_id: Ecto.UUID.generate(),
        assigns: %{}
      }

      :ok = TriggerNode.fire("engine:craft_email", map_event)

      assert [_run] = Workflows.list_runs(workflow.id),
             "a map payload lets TriggerNode create the SendLeadsEmail run"
    end

    test "an event-like map without assigns does not grant machine permissions" do
      assert {:ok, workflow} = SendLeadsEmail.create()

      event = %{
        request: %{"content" => "## Company Summary"},
        trace_id: Ecto.UUID.generate()
      }

      :ok = TriggerNode.fire("engine:craft_email", event)

      assert [run] = Workflows.list_runs(workflow.id)

      refute Map.get(run.source_event.assigns, :skip_permissions) ||
               Map.get(run.source_event.assigns, "skip_permissions")
    end
  end
end
