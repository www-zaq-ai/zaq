defmodule Zaq.NodeRouterContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.{Event, NodeRouter}

  @timestamp ~U[2026-01-01 00:00:00Z]
  @action :unsupported_node_router_coverage_action

  describe "dispatch_all/2 validation and discovery" do
    test "rejects async fanout without discovery or task startup" do
      marker = make_ref()

      event = fanout_event(:async, "async-rejection")

      runtime = %{
        current_node_fn: fn ->
          send(self(), {marker, :current_node})
          :local@host
        end,
        node_list_fn: fn ->
          send(self(), {marker, :node_list})
          []
        end,
        whereis_fn: fn supervisor ->
          send(self(), {marker, {:whereis, supervisor}})
          nil
        end,
        rpc_call_fn: fn node, module, function, args ->
          send(self(), {marker, {:rpc, {node, module, function, args}}})
          nil
        end,
        async_start_fn: fn fun ->
          send(self(), {marker, :async_start})
          {:ok, fun}
        end
      }

      assert NodeRouter.dispatch_all(event, runtime) == {:error, {:invalid_fanout, :async_hop}}
      refute_received {^marker, _}
    end

    test "normalizes raised discovery failures to the requested role" do
      marker = make_ref()

      runtime = discovery_failure_runtime(marker, fn -> raise "controlled discovery failure" end)

      assert NodeRouter.dispatch_all(fanout_event(:sync, "raised-discovery"), runtime) ==
               {:error, {:node_discovery_failed, :bo}}

      assert_received {^marker,
                       {:discovery, :broken@host, Process, :whereis, [ZaqWeb.Endpoint], 30_000}}

      refute_received {^marker, {:unexpected_call, _}}
      refute_received {^marker, :execution}
    end

    test "normalizes discovery throws" do
      marker = make_ref()

      runtime = discovery_failure_runtime(marker, fn -> throw(:controlled_discovery_throw) end)

      assert NodeRouter.dispatch_all(fanout_event(:sync, "thrown-discovery"), runtime) ==
               {:error, {:node_discovery_failed, :bo}}

      assert_received {^marker,
                       {:discovery, :broken@host, Process, :whereis, [ZaqWeb.Endpoint], 30_000}}

      refute_received {^marker, {:unexpected_call, _}}
      refute_received {^marker, :execution}
    end

    test "normalizes catchable discovery exits" do
      marker = make_ref()

      runtime = discovery_failure_runtime(marker, fn -> exit(:controlled_discovery_exit) end)

      assert NodeRouter.dispatch_all(fanout_event(:sync, "exited-discovery"), runtime) ==
               {:error, {:node_discovery_failed, :bo}}

      assert_received {^marker,
                       {:discovery, :broken@host, Process, :whereis, [ZaqWeb.Endpoint], 30_000}}

      refute_received {^marker, {:unexpected_call, _}}
      refute_received {^marker, :execution}
    end

    test "rejects a missing fanout next hop" do
      marker = make_ref()

      event = %Event{request: %{probe: :fanout}, next_hop: nil}

      assert NodeRouter.dispatch_all(event, callback_recording_runtime(marker)) ==
               {:error, {:invalid_event, :missing_or_invalid_next_hop}}

      refute_received {^marker, _}
    end

    test "rejects a plausible plain-map fanout hop independently of property sampling" do
      marker = make_ref()

      event = %Event{
        request: %{probe: :fanout},
        next_hop: %{destination: :bo, type: :sync}
      }

      assert NodeRouter.dispatch_all(event, callback_recording_runtime(marker)) ==
               {:error, {:invalid_event, :missing_or_invalid_next_hop}}

      refute_received {^marker, _}
    end

    property "non-struct hop maps never become routable fanout destinations" do
      check all(hop <- malformed_hop(), max_runs: 20) do
        marker = make_ref()
        event = %Event{request: %{probe: :fanout}, next_hop: hop}

        assert NodeRouter.dispatch_all(event, callback_recording_runtime(marker)) ==
                 {:error, {:invalid_event, :missing_or_invalid_next_hop}}

        refute_received {^marker, _}
      end
    end

    test "rejects representative non-map hops" do
      for hop <- [false, :bad_hop, [], "bo", 42] do
        marker = make_ref()
        event = %Event{request: %{probe: :fanout}, next_hop: hop}

        assert NodeRouter.dispatch_all(event, callback_recording_runtime(marker)) ==
                 {:error, {:invalid_event, :missing_or_invalid_next_hop}}

        refute_received {^marker, _}
      end
    end

    test "skips empty peers and still fans out to later owners" do
      marker = make_ref()
      owner = self()
      event = fanout_event(:sync, "skip-empty-peer")

      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:empty@host, :owner@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_with_timeout_fn: fn
          :empty@host, Process, :whereis, [ZaqWeb.Endpoint], 30_000 ->
            send(owner, {marker, {:discovery, :empty@host, 30_000}})
            nil

          :owner@host, Process, :whereis, [ZaqWeb.Endpoint], 30_000 ->
            send(owner, {marker, {:discovery, :owner@host, 30_000}})
            owner

          :owner@host, Zaq.Bo.Api, :handle_event, [%Event{} = routed, @action, nil], :infinity ->
            send(owner, {marker, {:execution, routed, :infinity}})
            %{routed | response: {:ack, :owner@host}}

          node, module, function, args, timeout ->
            send(owner, {marker, {:unexpected_call, {node, module, function, args, timeout}}})
            nil
        end
      }

      assert {:ok, [ack]} = NodeRouter.dispatch_all(event, runtime)
      assert ack.response == {:ack, :owner@host}
      assert ack.request == event.request
      assert ack.assigns == event.assigns
      assert ack.opts == event.opts
      assert ack.trace_id == event.trace_id
      assert ack.actor == event.actor
      assert ack.next_hop == nil
      assert ack.hops == [event.next_hop]

      assert_received {^marker, {:discovery, :empty@host, 30_000}}
      assert_received {^marker, {:discovery, :owner@host, 30_000}}
      assert_received {^marker, {:execution, %Event{} = routed, :infinity}}
      assert routed.request == event.request
      assert routed.next_hop == nil
      assert routed.hops == [event.next_hop]
      refute_received {^marker, {:unexpected_call, _}}
    end
  end

  defp fanout_event(type, trace_id) do
    Event.new(%{probe: :fanout}, :bo,
      type: type,
      timestamp: @timestamp,
      trace_id: trace_id,
      actor: %{actor: :coverage_test},
      assigns: %{assigns: :coverage_test},
      opts: [action: @action, confidential: true]
    )
  end

  defp discovery_failure_runtime(marker, failure) do
    owner = self()

    %{
      current_node_fn: fn -> :local@host end,
      node_list_fn: fn -> [:broken@host] end,
      whereis_fn: fn _ -> nil end,
      rpc_call_with_timeout_fn: fn
        :broken@host, Process, :whereis, [ZaqWeb.Endpoint], 30_000 ->
          send(
            owner,
            {marker, {:discovery, :broken@host, Process, :whereis, [ZaqWeb.Endpoint], 30_000}}
          )

          failure.()

        node, module, function, args, timeout ->
          send(owner, {marker, {:unexpected_call, {node, module, function, args, timeout}}})
          nil
      end
    }
  end

  defp callback_recording_runtime(marker) do
    owner = self()

    %{
      current_node_fn: fn ->
        send(owner, {marker, :current_node})
        :local@host
      end,
      node_list_fn: fn ->
        send(owner, {marker, :node_list})
        []
      end,
      whereis_fn: fn supervisor ->
        send(owner, {marker, {:whereis, supervisor}})
        nil
      end,
      rpc_call_fn: fn node, module, function, args ->
        send(owner, {marker, {:rpc, {node, module, function, args}}})
        nil
      end,
      rpc_call_with_timeout_fn: fn node, module, function, args, timeout ->
        send(owner, {marker, {:rpc_timeout, {node, module, function, args, timeout}}})
        nil
      end,
      async_start_fn: fn fun ->
        send(owner, {marker, :async_start})
        {:ok, fun}
      end
    }
  end

  defp malformed_hop do
    value =
      StreamData.one_of([
        StreamData.member_of([:bo, :sync, :async]),
        StreamData.integer(-100..100),
        StreamData.binary(max_length: 24)
      ])

    StreamData.one_of([
      StreamData.constant(%{destination: :bo, type: :sync}),
      StreamData.optional_map(%{
        destination: value,
        type: value,
        timestamp: value
      })
    ])
  end
end
