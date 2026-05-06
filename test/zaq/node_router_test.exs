defmodule Zaq.NodeRouterTest do
  use ExUnit.Case, async: true

  alias Zaq.{Event, EventHop, NodeRouter}

  describe "supervisor_map/0" do
    test "returns a map of all expected roles" do
      map = NodeRouter.supervisor_map()

      assert Map.has_key?(map, :agent)
      assert Map.has_key?(map, :ingestion)
      assert Map.has_key?(map, :channels)
      assert Map.has_key?(map, :engine)
      assert Map.has_key?(map, :bo)
    end

    test "maps roles to correct supervisors" do
      map = NodeRouter.supervisor_map()

      assert map[:agent] == Zaq.Agent.Supervisor
      assert map[:ingestion] == Zaq.Ingestion.Supervisor
      assert map[:channels] == Zaq.Channels.Supervisor
      assert map[:engine] == Zaq.Engine.Supervisor
      assert map[:bo] == ZaqWeb.Endpoint
    end
  end

  describe "find_node/1" do
    test "returns local node when supervisor is running locally" do
      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn
          :my_supervisor -> self()
          _ -> nil
        end,
        rpc_call_fn: fn _n, Process, :whereis, [_supervisor] -> nil end
      }

      assert NodeRouter.find_node(:my_supervisor, runtime) == :local@host
    end

    test "returns remote node when supervisor is absent locally" do
      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :remote@host, Process, :whereis, [:my_supervisor] -> spawn(fn -> :ok end)
          _n, Process, :whereis, [_supervisor] -> nil
        end
      }

      assert NodeRouter.find_node(:my_supervisor, runtime) == :remote@host
    end

    test "falls back to local node when all remote lookups fail" do
      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:down@host, :empty@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :down@host, Process, :whereis, [_supervisor] -> {:badrpc, :nodedown}
          :empty@host, Process, :whereis, [_supervisor] -> nil
        end
      }

      assert NodeRouter.find_node(:my_supervisor, runtime) == :local@host
    end
  end

  describe "call/4" do
    test "calls function locally when service runs on local node" do
      result = NodeRouter.call(:bo, String, :upcase, ["hello"])
      assert result == "HELLO"
    end

    test "dispatches to local node for bo role since endpoint is running" do
      result = NodeRouter.call(:bo, Kernel, :node, [])
      assert result == node()
    end

    test "falls back to local apply when role supervisor is not found" do
      result = NodeRouter.call(:agent, String, :replace, ["abc", "a", "z"])
      assert result == "zbc"
    end

    test "uses rpc for remote target and returns remote result" do
      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] ->
            spawn(fn -> :ok end)

          :remote@host, Zaq.Agent.Api, :handle_event, [event, :invoke, _api_opts] ->
            %{event | response: "HELLO FROM REMOTE"}
        end
      }

      assert NodeRouter.call(:agent, String, :upcase, ["hello"], runtime) == "HELLO FROM REMOTE"
    end

    test "wraps badrpc failures from remote calls" do
      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] ->
            spawn(fn -> :ok end)

          :remote@host, Zaq.Agent.Api, :handle_event, [_event, :invoke, _api_opts] ->
            {:badrpc, :timeout}
        end
      }

      assert NodeRouter.call(:agent, String, :upcase, ["hello"], runtime) ==
               {:error, {:rpc_failed, :remote@host, :timeout}}
    end

    test "raises for unknown role" do
      assert_raise KeyError, fn ->
        NodeRouter.call(:unknown, String, :upcase, ["hello"])
      end
    end
  end

  describe "dispatch/1" do
    test "dispatches invoke events locally" do
      event =
        Event.new(%{module: String, function: :upcase, args: ["hello"]}, :bo,
          opts: [action: :invoke]
        )

      result = NodeRouter.dispatch(event)
      assert %Event{} = result
      assert result.response == "HELLO"
      assert result.hops == [result.next_hop]
    end

    test "dispatches invoke events remotely and returns routed event" do
      event =
        Event.new(%{module: String, function: :upcase, args: ["hello"]}, :agent,
          opts: [action: :invoke]
        )

      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] ->
            spawn(fn -> :ok end)

          :remote@host, Zaq.Agent.Api, :handle_event, [%Event{} = routed, :invoke, _api_opts] ->
            %{routed | response: "HELLO FROM REMOTE"}
        end
      }

      result = NodeRouter.dispatch(event, runtime)
      assert %Event{} = result
      assert result.response == "HELLO FROM REMOTE"
      assert result.hops == [result.next_hop]
    end

    test "returns invalid_event_response when remote handler does not return event" do
      event = Event.new(%{module: String, function: :upcase, args: ["hello"]}, :agent)

      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] ->
            spawn(fn -> :ok end)

          :remote@host, Zaq.Agent.Api, :handle_event, [_event, :invoke, _api_opts] ->
            :not_an_event
        end
      }

      result = NodeRouter.dispatch(event, runtime)

      assert result.response == {:error, {:invalid_event_response, :remote@host, :not_an_event}}
    end

    test "wraps remote badrpc failures in the event response" do
      event =
        Event.new(%{module: String, function: :upcase, args: ["hello"]}, :agent,
          opts: [action: :invoke]
        )

      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] ->
            spawn(fn -> :ok end)

          :remote@host, Zaq.Agent.Api, :handle_event, [%Event{}, :invoke, _api_opts] ->
            {:badrpc, :timeout}
        end
      }

      result = NodeRouter.dispatch(event, runtime)

      assert %Event{} = result

      assert result.response == {:error, {:rpc_failed, :remote@host, :timeout}}
      assert result.hops == [result.next_hop]
    end

    test "returns the appended event immediately for async hops" do
      event = %Event{
        request: %{module: String, function: :upcase, args: ["hello"]},
        next_hop: %EventHop{destination: :bo, type: :async, timestamp: DateTime.utc_now()},
        opts: [action: :invoke],
        trace_id: Ecto.UUID.generate()
      }

      result = NodeRouter.dispatch(event)

      assert %Event{} = result
      assert result.response == nil
      assert result.hops == [result.next_hop]
    end

    test "executes async remote hops in background and returns immediately" do
      event =
        Event.new(%{module: String, function: :upcase, args: ["hello"]}, :agent,
          type: :async,
          opts: [action: :invoke]
        )

      parent = self()

      runtime = %{
        current_node_fn: fn -> :local@host end,
        node_list_fn: fn -> [:remote@host] end,
        whereis_fn: fn _ -> nil end,
        rpc_call_fn: fn
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] ->
            spawn(fn -> :ok end)

          :remote@host, Zaq.Agent.Api, :handle_event, [%Event{} = routed, :invoke, _api_opts] ->
            send(parent, {:async_remote_called, routed.trace_id})
            %{routed | response: "HELLO FROM REMOTE"}
        end
      }

      result = NodeRouter.dispatch(event, runtime)
      trace_id = event.trace_id

      assert %Event{} = result
      assert result.trace_id == trace_id
      assert result.response == nil
      assert result.hops == [result.next_hop]
      assert_receive {:async_remote_called, ^trace_id}
    end

    test "does not duplicate last hop when dispatching same event twice" do
      event =
        Event.new(%{module: String, function: :upcase, args: ["hello"]}, :bo,
          opts: [action: :invoke]
        )

      first = NodeRouter.dispatch(event)
      second = NodeRouter.dispatch(first)

      assert length(second.hops) == 1
      assert second.hops == [second.next_hop]
    end

    test "normalizes non-atom action in opts to invoke" do
      event =
        Event.new(%{module: String, function: :upcase, args: ["hello"]}, :bo,
          opts: [action: "bad"]
        )

      result = NodeRouter.dispatch(event)

      assert result.response == "HELLO"
    end

    test "normalizes non-list opts to invoke via fallback" do
      event = %Event{
        request: %{module: String, function: :upcase, args: ["hello"]},
        next_hop: %EventHop{destination: :bo, type: :sync, timestamp: DateTime.utc_now()},
        opts: %{action: :invoke},
        trace_id: Ecto.UUID.generate(),
        hops: []
      }

      result = NodeRouter.dispatch(event)

      assert result.response == "HELLO"
    end

    test "append_current_hop ignores invalid hop list shape" do
      event = %Event{
        request: %{module: String, function: :upcase, args: ["hello"]},
        next_hop: %EventHop{destination: :bo, type: :sync, timestamp: DateTime.utc_now()},
        opts: [action: :invoke],
        trace_id: Ecto.UUID.generate(),
        hops: nil
      }

      result = NodeRouter.dispatch(event)

      assert result.response == "HELLO"
      assert result.hops == nil
    end

    test "returns invalid_event when next_hop is nil" do
      event = %Event{
        request: %{module: String, function: :upcase, args: ["hello"]},
        next_hop: nil,
        opts: [action: :invoke],
        trace_id: Ecto.UUID.generate(),
        hops: []
      }

      result = NodeRouter.dispatch(event)

      assert result.response == {:error, {:invalid_event, :missing_or_invalid_next_hop}}
    end

    test "returns invalid_event when next_hop has invalid shape" do
      event = %Event{
        request: %{module: String, function: :upcase, args: ["hello"]},
        next_hop: %{destination: :bo},
        opts: [action: :invoke],
        trace_id: Ecto.UUID.generate(),
        hops: []
      }

      result = NodeRouter.dispatch(event)

      assert result.response == {:error, {:invalid_event, :missing_or_invalid_next_hop}}
    end

    test "find_node/1 delegates to default runtime" do
      assert NodeRouter.find_node(ZaqWeb.Endpoint) == node()
    end
  end
end
