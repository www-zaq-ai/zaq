defmodule Zaq.Engine.Workflows.DispatchFiftyItemsTest do
  @moduledoc """
  Covers the `UseCases.DispatchFiftyItems` example: a 50-item list fanned out
  through a `Batch` node, dispatching one `lead_identified` event per item.

  The real `DispatchEvent` defaults to the live `Zaq.NodeRouter`, which the
  `StepRunner` does not override. A `BridgeDispatchEvent` wrapper injects the Mox
  router (whose stub captures each dispatched event) while delegating all real
  request/machine logic to the production tool — the same seam the lead-pipeline
  e2e test uses. Runs `async: false` because the batch executes in `Task` children
  that share the Ecto sandbox.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.UseCases.DispatchFiftyItems

  # Routes the real DispatchEvent through the Mox router so the dispatched events
  # can be captured, without hitting the live engine node.
  defmodule BridgeDispatchEvent do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "bridge_dispatch_event",
      schema: [
        input: [type: :map, required: true],
        event_name: [type: :string, required: true],
        machine: [type: :boolean, required: false, default: false]
      ],
      output_schema: [dispatched: [type: :map, required: true]]

    @impl Jido.Action
    def run(params, ctx) do
      DispatchEvent.run(params, Map.put(ctx, :node_router, Zaq.NodeRouterMock))
    end
  end

  setup do
    test_pid = self()

    Mox.set_mox_global()

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      if event.name == "lead_identified", do: send(test_pid, {:dispatched, event})
      event
    end)

    :ok
  end

  test "seeds 50 items, fans out via Batch, and dispatches one event per item" do
    build = swap_dispatch_module(DispatchFiftyItems.build())

    {:ok, workflow} = Workflows.create_workflow(build)

    source_event = %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual", "input" => %{}},
      "trace_id" => Ecto.UUID.generate()
    }

    assert {:ok, run} = Workflows.create_and_start_run(workflow, source_event)
    assert run.status == "completed"

    dispatched = drain_dispatched([])

    assert length(dispatched) == 50, "expected one lead_identified event per item"

    # Every dispatched event carries its item payload (the 50 distinct ids).
    ids =
      dispatched
      |> Enum.map(fn event ->
        req = event.request || %{}
        Map.get(req, "id") || Map.get(req, :id)
      end)
      |> Enum.sort()

    assert ids == Enum.to_list(1..50)
  end

  test "build/0 is a persistable, valid workflow definition" do
    assert {:ok, workflow} = Workflows.create_workflow(DispatchFiftyItems.build())
    assert workflow.status == "active"
    assert Enum.any?(workflow.nodes, &(&1.name == "process_items"))
  end

  # Point the batch body's dispatch step at the bridge so dispatches hit the Mox
  # router; everything else stays the production definition.
  defp swap_dispatch_module(build) do
    nodes =
      Enum.map(build.nodes, fn node ->
        if node.name == "process_items", do: patch_batch(node), else: node
      end)

    %{build | nodes: nodes}
  end

  defp patch_batch(node) do
    process =
      Enum.map(node.params["process"], fn bnode ->
        if bnode["name"] == "dispatch_item",
          do: Map.put(bnode, "module", inspect(BridgeDispatchEvent)),
          else: bnode
      end)

    %{node | params: Map.put(node.params, "process", process)}
  end

  defp drain_dispatched(acc) do
    receive do
      {:dispatched, event} -> drain_dispatched([event | acc])
    after
      0 -> acc
    end
  end
end
