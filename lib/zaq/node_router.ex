defmodule Zaq.NodeRouter do
  @moduledoc """
  Routes function calls to the correct node based on which supervisor
  is running where.

  When services are split across nodes (e.g. agent on ai@localhost,
  bo on bo@localhost), direct local calls won't work. This module
  checks all connected nodes and dispatches via :rpc.call/4 to the
  node where the supervisor is actually running.

  Falls back to a local call if no peer node has the supervisor,
  which handles the single-node (all roles) case transparently.

  ## Example

      # Calls Zaq.Agent.Retrieval.ask/2 on whichever node runs Zaq.Agent.Supervisor
      NodeRouter.call(:agent, Zaq.Agent.Retrieval, :ask, [question, opts])
  """

  @supervisor_map %{
    agent: Zaq.Agent.Supervisor,
    ingestion: Zaq.Ingestion.Supervisor,
    channels: Zaq.Channels.Supervisor,
    engine: Zaq.Engine.Supervisor,
    bo: ZaqWeb.Endpoint
  }

  @doc """
  Returns the supervisor map. Used by ServiceUnavailable component
  and other modules that need to check role → supervisor mapping.
  """
  def supervisor_map, do: @supervisor_map

  @doc """
  Calls mod.fun(args) on the node running the given service role.
  Falls back to a local call if the service runs locally or no peer has it.
  """
  def call(role, mod, fun, args) do
    supervisor = Map.fetch!(@supervisor_map, role)
    target = find_node(supervisor)

    if target == node() do
      apply(mod, fun, args)
    else
      case :rpc.call(target, mod, fun, args) do
        {:badrpc, reason} -> {:error, {:rpc_failed, target, reason}}
        result -> result
      end
    end
  end

  @doc """
  Returns the node where the given supervisor is running.
  Checks local node first, then all connected peers.
  Returns the local node as fallback if not found anywhere.
  """
  def find_node(supervisor) do
    all_nodes = [node() | Node.list()]
    Enum.find(all_nodes, node(), &supervisor_running?(&1, supervisor))
  end

  defp supervisor_running?(n, supervisor) when n == node() do
    Process.whereis(supervisor) != nil
  end

  defp supervisor_running?(n, supervisor) do
    case :rpc.call(n, Process, :whereis, [supervisor]) do
      {:badrpc, _} -> false
      nil -> false
      _pid -> true
    end
  end
end
