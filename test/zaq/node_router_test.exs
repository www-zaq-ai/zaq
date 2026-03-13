defmodule Zaq.NodeRouterTest do
  use ExUnit.Case, async: true

  alias Zaq.NodeRouter

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
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] -> spawn(fn -> :ok end)
          :remote@host, String, :upcase, ["hello"] -> "HELLO FROM REMOTE"
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
          :remote@host, Process, :whereis, [Zaq.Agent.Supervisor] -> spawn(fn -> :ok end)
          :remote@host, String, :upcase, ["hello"] -> {:badrpc, :timeout}
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
end
