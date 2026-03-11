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
      # ZaqWeb.Endpoint is always running in test env
      result = NodeRouter.find_node(ZaqWeb.Endpoint)
      assert result == node()
    end

    test "returns local node as fallback when supervisor is not found anywhere" do
      # A supervisor that is definitely not running
      result = NodeRouter.find_node(Zaq.Agent.Supervisor)
      assert result == node()
    end

    test "does not crash when Node.list() is empty" do
      # In test env there are no peer nodes — should still return local node
      assert Node.list() == []
      result = NodeRouter.find_node(ZaqWeb.Endpoint)
      assert is_atom(result)
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

    test "raises for unknown role" do
      assert_raise KeyError, fn ->
        NodeRouter.call(:unknown, String, :upcase, ["hello"])
      end
    end
  end
end
