defmodule Zaq.ExtensionDispatchTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Extension.Invocation
  alias Zaq.{Event, NodeRouter}

  test "tracked async dispatch returns its worker and sends a confidential correlated completion Event" do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    generation = make_ref()
    id = Ecto.UUID.generate()

    event =
      Event.new(%Invocation{operation: :list, page_size: 1}, :engine,
        type: :async,
        trace_id: id,
        opts: [action: :extension_action, confidential: true, track_dispatch: true],
        assigns: %{extension_owner: self(), extension_generation: generation}
      )

    assert %Event{assigns: %{async_task_pid: pid}} = NodeRouter.dispatch(event)
    assert is_pid(pid)
    assert_receive {:extension_action_completed, ^generation, ^id, {:listed, page}}, 1_000
    assert length(page.actions) == 1

    unrelated = Event.new(%{}, :engine)
    NodeRouter.fire(unrelated)
    assert_receive {:node_router_event, ^unrelated}
    refute_receive {:node_router_event, %Event{trace_id: ^id}}
  end

  test "tracked async dispatch reports task-supervisor admission failure without claiming success" do
    event =
      Event.new(nil, :engine,
        type: :async,
        opts: [action: :extension_action, track_dispatch: true]
      )

    runtime = %{async_start_fn: fn _fun -> {:error, :max_children} end}
    assert %Event{response: {:error, :dispatch_unavailable}} = NodeRouter.dispatch(event, runtime)
    runtime = %{async_start_fn: fn _fun -> exit(:noproc) end}
    assert %Event{response: {:error, :dispatch_unavailable}} = NodeRouter.dispatch(event, runtime)
  end
end
