defmodule Zaq.Agent.MCP.SignalAdapter do
  @moduledoc """
  Sends jido_mcp plugin signals to agent processes and extracts results.

  All MCP runtime operations (register, refresh, sync, unsync, unregister)
  go through standard plugin signals routed by the agent's SignalRouter.
  No direct Jido.MCP API calls are made from ZAQ orchestration.
  """

  require Logger

  @default_timeout 15_000

  @spec sync_tools(GenServer.server(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_tools(server_ref, runtime_endpoint_id, opts \\ []) do
    signal =
      Jido.Signal.new!(
        "mcp.ai.sync_tools",
        %{
          endpoint_id: runtime_endpoint_id,
          agent_server: server_ref,
          prefix: Keyword.get(opts, :mcp_tool_prefix, ""),
          replace_existing: Keyword.get(opts, :mcp_tool_replace_existing, true)
        },
        source: "/zaq/mcp"
      )

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Jido.AgentServer.call(server_ref, signal, timeout) do
      {:ok, agent} ->
        {:ok,
         Map.take(
           agent.state,
           [
             :endpoint_id,
             :discovered_count,
             :registered_count,
             :failed_count,
             :failed,
             :warnings,
             :skipped_count,
             :registered_tools
           ]
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec unsync_tools(GenServer.server(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def unsync_tools(server_ref, runtime_endpoint_id, opts \\ []) do
    signal =
      Jido.Signal.new!(
        "mcp.ai.unsync_tools",
        %{
          endpoint_id: runtime_endpoint_id,
          agent_server: server_ref
        },
        source: "/zaq/mcp"
      )

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Jido.AgentServer.call(server_ref, signal, timeout) do
      {:ok, agent} ->
        {:ok,
         Map.take(agent.state, [
           :endpoint_id,
           :removed_count,
           :failed_count,
           :removed_tools,
           :failed,
           :purged_count,
           :retained_count,
           :purge_failed_count
         ])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec register_endpoint(GenServer.server(), map(), keyword()) ::
          :ok | {:error, term()}
  def register_endpoint(server_ref, endpoint_attrs, opts \\ []) do
    signal =
      Jido.Signal.new!("mcp.endpoint.register", endpoint_attrs, source: "/zaq/mcp")

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Jido.AgentServer.call(server_ref, signal, timeout) do
      {:ok, _agent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec refresh_endpoint(GenServer.server(), atom(), keyword()) ::
          :ok | {:error, term()}
  def refresh_endpoint(server_ref, runtime_endpoint_id, opts \\ []) do
    signal =
      Jido.Signal.new!(
        "mcp.endpoint.refresh",
        %{
          endpoint_id: runtime_endpoint_id
        },
        source: "/zaq/mcp"
      )

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Jido.AgentServer.call(server_ref, signal, timeout) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unregister_endpoint(GenServer.server(), atom(), keyword()) ::
          :ok | {:error, term()}
  def unregister_endpoint(server_ref, runtime_endpoint_id, opts \\ []) do
    signal =
      Jido.Signal.new!(
        "mcp.endpoint.unregister",
        %{
          endpoint_id: runtime_endpoint_id
        },
        source: "/zaq/mcp"
      )

    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Jido.AgentServer.call(server_ref, signal, timeout) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
