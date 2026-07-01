defmodule Zaq.Engine.Workflows.DispatchEventWorkflowTest do
  @moduledoc """
  Exercises `DispatchEvent` in three shapes within a single workflow run:

    1. As a plain second node with **no `input` mapping** — it forwards the merged
       outputs of every prior step (the run's cascade). Reaches `:engine`.
    2. Inside a `Batch` body **with a per-item `input`** — each fan-out fork
       dispatches its own item. Reaches `:engine`.
    3. As a node with an explicit **`destination: "channels"`** and a string
       message `input`. Reaches `:channels`.

  Each dispatch must reach the correct node role with the correct request payload.

  The real `DispatchEvent` defaults to the live `Zaq.NodeRouter`, so a
  `BridgeDispatchEvent` wrapper injects the Mox router (whose stub captures every
  dispatched event) while delegating all request/machine logic to the production
  tool. `async: false` because the batch runs in `Task` children sharing the Ecto
  sandbox.
  """
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Engine.Workflows

  @batch_module "Zaq.Agent.Tools.Workflow.Batch"

  # ── Inline step modules ────────────────────────────────────────────────────────

  # First node: emits facts the second (no-input) DispatchEvent node forwards.
  defmodule SeedLead do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "seed_lead",
      description: "Emit a readiness fact plus a payload field.",
      schema: [count: [type: :integer, required: false, default: 1, doc: "Unused."]],
      output_schema: [
        ready: [type: :boolean, required: true, doc: "Always true."],
        lead_id: [type: :integer, required: true, doc: "A payload field to forward."]
      ]

    @impl Jido.Action
    def run(_params, _ctx), do: {:ok, %{ready: true, lead_id: 7}}
  end

  # Emits the fixed list of items the batch fans out over.
  defmodule SeedItems do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "seed_items",
      description: "Emit a fixed list of items to fan out over.",
      schema: [count: [type: :integer, required: false, default: 3, doc: "How many items."]],
      output_schema: [items: [type: {:list, :map}, required: true, doc: "Items to dispatch."]]

    @impl Jido.Action
    def run(params, _ctx) do
      count = Map.get(params, :count, 3)

      items =
        Enum.map(1..count, fn i ->
          %{"id" => i, "email" => "user#{i}@example.com", "name" => "User #{i}"}
        end)

      {:ok, %{items: items}}
    end
  end

  # Identity step: one required `input` makes it the batch's fan-out field, and
  # forwarding `input` lets the downstream DispatchEvent send it as the payload.
  defmodule PrepareItem do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "prepare_item",
      description: "Pass a single batch item through as `input`.",
      schema: [input: [type: :map, required: true, doc: "One item from the batch."]],
      output_schema: [input: [type: :map, required: true, doc: "The item, unchanged."]]

    @impl Jido.Action
    def run(%{input: input}, _ctx), do: {:ok, %{input: input}}
  end

  # Routes the real DispatchEvent through the Mox router so events are captured
  # without hitting the live engine node. `input` is optional (as in production).
  defmodule BridgeDispatchEvent do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "bridge_dispatch_event",
      schema: [
        input: [type: :any, required: false, default: %{}],
        event_name: [type: :string, required: true],
        destination: [type: :string, required: false, default: "engine"],
        machine: [type: :boolean, required: false, default: false]
      ],
      output_schema: [dispatched: [type: :any, required: true]]

    @impl Jido.Action
    def run(params, ctx) do
      DispatchEvent.run(params, Map.put(ctx, :node_router, Zaq.NodeRouterMock))
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────────────

  setup do
    test_pid = self()

    Mox.set_mox_global()

    # Capture every dispatched event, regardless of name.
    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(test_pid, {:dispatched, event})
      event
    end)

    :ok
  end

  # ── Test ───────────────────────────────────────────────────────────────────────

  test "dispatches from a no-input second node, a per-item batch, and a channels node to the right destinations" do
    {:ok, workflow} = Workflows.create_workflow(build())

    source_event = %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual", "input" => %{}},
      "trace_id" => Ecto.UUID.generate()
    }

    assert {:ok, run} = Workflows.create_and_start_run(workflow, source_event)
    assert run.status == "completed"

    events = drain_dispatched([])

    # ── Step 1: the no-input second node forwards the prior step's outputs ──────
    lead_ready = Enum.filter(events, &(&1.name == "lead_ready"))
    assert length(lead_ready) == 1
    [ready_event] = lead_ready

    assert ready_event.next_hop.destination == :engine
    assert ready_event.next_hop.type == :async
    # No `input` mapping → the request is exactly `seed_lead`'s output.
    assert ready_event.request == %{"ready" => true, "lead_id" => 7}

    # ── Step 2: the batch dispatches one event per item, each with its payload ──
    lead_identified = Enum.filter(events, &(&1.name == "lead_identified"))
    assert length(lead_identified) == 3, "expected one lead_identified event per item"

    for event <- lead_identified do
      assert event.next_hop.destination == :engine
      assert event.next_hop.type == :async
    end

    # Each per-item event carries its own item payload (distinct ids 1..3).
    by_id =
      Map.new(lead_identified, fn event -> {event.request["id"], event.request} end)

    assert Map.keys(by_id) |> Enum.sort() == [1, 2, 3]

    for i <- 1..3 do
      req = by_id[i]
      assert req["id"] == i
      assert req["email"] == "user#{i}@example.com"
      assert req["name"] == "User #{i}"
      # The batch node set `machine: true` — the marker rides on each dispatch.
      assert req["machine"] == true
    end

    # The no-input second-node dispatch carried no machine marker.
    refute Map.has_key?(ready_event.request, "machine")

    # ── Step 3: the channels dispatch routes to :channels with a string message ─
    channel_events = Enum.filter(events, &(&1.name == "notify_channel"))
    assert length(channel_events) == 1
    [channel_event] = channel_events

    assert channel_event.next_hop.destination == :channels
    assert channel_event.next_hop.type == :async
    # The scalar `input` is dispatched verbatim — the request IS the string, not a map.
    assert channel_event.request == "seeds ready"
    assert is_binary(channel_event.request)
  end

  # ── Workflow definition ─────────────────────────────────────────────────────────
  #
  #   seed_lead ──(ready eq true)──> dispatch_lead        (DispatchEvent, no input)
  #   dispatch_lead ──(dispatched not_empty)──> seed_items
  #   seed_items ──(items not_empty, items→items)──> process_items  (Batch)
  #       process: [prepare_item, dispatch_item]          (DispatchEvent, per-item input)
  #   seed_items ──(items not_empty)──> dispatch_channel  (DispatchEvent, destination: channels)
  defp build do
    %{
      name: "Dispatch Event Workflow",
      description: "A no-input second-node dispatch and a per-item batch dispatch.",
      status: "active",
      nodes: [
        %{name: "seed_lead", type: "action", module: inspect(SeedLead), params: %{}, index: 0},
        %{
          name: "dispatch_lead",
          type: "action",
          module: inspect(BridgeDispatchEvent),
          params: %{"event_name" => "lead_ready"},
          index: 1
        },
        %{name: "seed_items", type: "action", module: inspect(SeedItems), params: %{}, index: 2},
        %{
          name: "process_items",
          type: "action",
          module: @batch_module,
          params: %{
            "delivery" => "item",
            "strategy" => "skip_and_continue",
            "batch_size" => 5,
            "process" => [
              %{
                "name" => "prepare_item",
                "type" => "action",
                "module" => inspect(PrepareItem),
                "params" => %{}
              },
              %{
                "name" => "dispatch_item",
                "type" => "action",
                "module" => inspect(BridgeDispatchEvent),
                "params" => %{"event_name" => "lead_identified", "machine" => true}
              }
            ]
          },
          index: 3
        },
        %{
          name: "dispatch_channel",
          type: "action",
          module: inspect(BridgeDispatchEvent),
          # Routed to the channels node with a bare string payload (not a map) —
          # a scalar `input` is dispatched verbatim as the request.
          params: %{
            "event_name" => "notify_channel",
            "destination" => "channels",
            "input" => "seeds ready"
          },
          index: 4
        }
      ],
      edges: [
        %{
          from: "seed_lead",
          to: "dispatch_lead",
          condition: %{"field" => "ready", "op" => "eq", "value" => true}
        },
        %{
          from: "dispatch_lead",
          to: "seed_items",
          condition: %{"field" => "dispatched", "op" => "not_empty"}
        },
        %{
          from: "seed_items",
          to: "process_items",
          condition: %{"field" => "items", "op" => "not_empty"},
          mapping: %{"items" => "items"}
        },
        %{
          from: "seed_items",
          to: "dispatch_channel",
          condition: %{"field" => "items", "op" => "not_empty"}
        }
      ]
    }
  end

  defp drain_dispatched(acc) do
    receive do
      {:dispatched, event} -> drain_dispatched([event | acc])
    after
      200 -> acc
    end
  end
end
