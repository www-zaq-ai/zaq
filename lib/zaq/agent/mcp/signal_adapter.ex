defmodule Zaq.Agent.MCP.SignalAdapter do
  @moduledoc """
  Sends jido_mcp plugin signals to agent processes and extracts results.

  All MCP runtime operations (register, refresh, sync, unsync, unregister)
  go through standard plugin signals routed by the agent's SignalRouter.
  No direct Jido.MCP API calls are made from ZAQ orchestration.
  """

  require Logger

  @default_timeout 15_000

  @doc """
  Dispatches an `mcp.ai.sync_tools` signal to discover and register an endpoint's tools on the agent server.

  Returns `{:ok, map}` with tool counts and results extracted from the agent state, or `{:error, reason}`.

  ## Examples

      iex> Zaq.Agent.MCP.SignalAdapter.sync_tools(:nonexistent_agent, :my_endpoint)
      {:error, :not_found}

  """
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
        # We aligned with the Jido action returned map
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

  @doc """
  Dispatches an `mcp.ai.unsync_tools` signal to remove an endpoint's tools from the agent server.

  Returns `{:ok, map}` with removal counts and results, or `{:error, reason}`.

  ## Examples

      iex> Zaq.Agent.MCP.SignalAdapter.unsync_tools(:nonexistent_agent, :my_endpoint)
      {:error, :not_found}

  """
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
        # We aligned with the Jido action returned map
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

  @doc """
  Dispatches an `mcp.endpoint.register` signal to register an MCP endpoint on the agent server.

  `endpoint_attrs` is the full endpoint attribute map built by `Runtime.build_endpoint_attrs/2`.
  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> Zaq.Agent.MCP.SignalAdapter.register_endpoint(:nonexistent_agent, %{})
      {:error, :not_found}

  """
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

  @doc """
  Dispatches an `mcp.endpoint.refresh` signal to reconnect and reload an already-registered endpoint.

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> Zaq.Agent.MCP.SignalAdapter.refresh_endpoint(:nonexistent_agent, :my_endpoint)
      {:error, :not_found}

  """
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

  @doc """
  Dispatches an `mcp.endpoint.unregister` signal to fully remove an endpoint from the agent server.

  Only called when the endpoint has no remaining subscribers in the `ProxyRegistry`.
  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> Zaq.Agent.MCP.SignalAdapter.unregister_endpoint(:nonexistent_agent, :my_endpoint)
      {:error, :not_found}

  """
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
