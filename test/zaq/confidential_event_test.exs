defmodule Zaq.ConfidentialEventTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.{Event, NodeRouter}

  property "confidential requests never enter the observer stream but still dispatch" do
    check all(secret <- binary(), max_runs: 20) do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")

      event =
        Event.new(%{module: Function, function: :identity, args: [secret]}, :bo,
          opts: [action: :invoke, confidential: true]
        )

      assert NodeRouter.fire(event) == event
      assert NodeRouter.dispatch(event).response == secret
      refute_received {:node_router_event, ^event}
    end
  end

  test "request payload cannot opt out of observation" do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    event = Event.new(%{confidential: true}, :bo)
    NodeRouter.fire(event)
    assert_received {:node_router_event, ^event}
  end

  test "legacy invoke remains observable and returns its normal response" do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    assert NodeRouter.invoke(:bo, String, :upcase, ["public"]) == "PUBLIC"
    assert_received {:node_router_event, %{request: %{module: String, function: :upcase}}}
  end

  test "remote continuation preserves confidentiality at every routed hop" do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    event = Event.new(%{token: "remote-bearer"}, :engine, opts: [confidential: true])

    runtime = %{
      current_node_fn: fn -> :local@host end,
      node_list_fn: fn -> [:remote@host] end,
      whereis_fn: fn _ -> nil end,
      rpc_call_fn: fn
        :remote@host, Process, :whereis, [_] ->
          self()

        :remote@host, Zaq.Engine.Api, :handle_event, [event, _, _] ->
          assert event.opts[:confidential]
          %{event | next_hop: Zaq.EventHop.new(:bo, :sync, DateTime.utc_now())}

        :remote@host, Zaq.Bo.Api, :handle_event, [event, _, _] ->
          assert event.opts[:confidential]
          %{event | response: :completed}
      end
    }

    assert %{response: :completed, hops: [_, _]} = NodeRouter.dispatch(event, runtime)
    refute_received {:node_router_event, _}
  end

  test "asynchronous failure diagnostics omit secret request fields and returned reasons" do
    event =
      Event.new(
        %{
          module: Function,
          function: :identity,
          args: [{:error, "private-bearer"}],
          provider: "private-provider"
        },
        :bo,
        type: :async,
        opts: [confidential: true]
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        NodeRouter.dispatch(event, %{
          async_start_fn: fn fun ->
            fun.()
            {:ok, self()}
          end
        })
      end)

    assert log =~ "confidential_dispatch_failed"
    refute log =~ "private-bearer"
    refute log =~ "private-provider"
  end
end
