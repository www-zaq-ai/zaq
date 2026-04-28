defmodule Zaq.Agent.RuntimeSync do
  @moduledoc """
  Executor-side orchestration for configured agent and MCP runtime updates.
  """

  require Logger

  alias Jido.MCP.JidoAI.ProxyRegistry
  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.MCP.Runtime
  alias Zaq.Agent.MCP.SignalAdapter
  alias Zaq.Agent.ServerManager
  alias Zaq.Agent.Tools.Registry

  @spec sync_agent_runtime(ConfiguredAgent.t(), GenServer.server(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_agent_runtime(%ConfiguredAgent{} = agent, server_ref, opts \\ []) do
    with {:ok, tools} <- sync_agent_configured_tools(agent, server_ref, opts),
         {:ok, mcp} <- sync_agent_mcp_assignments(agent, server_ref, opts) do
      {:ok, %{tools: tools, mcp: mcp}}
    end
  end

  @spec sync_agent_mcp_assignments(ConfiguredAgent.t(), GenServer.server(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_agent_mcp_assignments(%ConfiguredAgent{} = agent, server_ref, opts \\ []) do
    endpoint_ids = agent.enabled_mcp_endpoint_ids || []
    mcp_module = Keyword.get(opts, :mcp_module, MCP)

    reduce_result =
      Enum.reduce_while(endpoint_ids, {[], [], [], []}, fn endpoint_id,
                                                           {synced_acc, skipped_acc, warnings_acc,
                                                            results_acc} ->
        case sync_added_endpoint(server_ref, endpoint_id, opts, mcp_module) do
          {:ok, %{status: :ok} = result} ->
            {:cont,
             {[endpoint_id | synced_acc], skipped_acc, warnings_acc, [result | results_acc]}}

          {:ok, %{status: :warning} = result} ->
            {:cont,
             {[endpoint_id | synced_acc], skipped_acc, [result | warnings_acc],
              [result | results_acc]}}

          {:ok, %{status: :skipped} = result} ->
            {:cont,
             {synced_acc, [endpoint_id | skipped_acc], warnings_acc, [result | results_acc]}}

          {:error, reason} ->
            {:halt,
             {:error,
              {:mcp_sync_failed,
               %{endpoint_id: endpoint_id, reason: reason, results: Enum.reverse(results_acc)}}}}
        end
      end)

    case reduce_result do
      {:error, _reason} = error ->
        error

      {synced, skipped, warnings, results} ->
        if warnings != [] do
          Logger.warning("MCP sync warnings for agent #{agent.id}: #{inspect(warnings)}")
        end

        {:ok,
         %{
           synced_endpoint_ids: Enum.reverse(synced),
           skipped_endpoint_ids: Enum.reverse(skipped),
           warnings: Enum.reverse(warnings),
           results: Enum.reverse(results)
         }}
    end
  end

  @spec sync_agent_configured_tools(ConfiguredAgent.t(), GenServer.server(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def sync_agent_configured_tools(%ConfiguredAgent{} = agent, server_ref, opts \\ []) do
    with {:ok, desired_tools} <- Registry.resolve_modules(agent.enabled_tool_keys || []),
         {:ok, current_tools} <- list_tools(server_ref, opts) do
      managed_tools = managed_tool_modules()

      desired_set = MapSet.new(desired_tools)
      current_set = MapSet.new(current_tools)

      to_add = MapSet.difference(desired_set, current_set) |> MapSet.to_list()

      to_remove =
        current_tools
        |> Enum.filter(&MapSet.member?(managed_tools, &1))
        |> Enum.reject(&MapSet.member?(desired_set, &1))

      added_results = Enum.map(to_add, &register_tool(server_ref, &1, opts))
      removed_results = Enum.map(to_remove, &unregister_tool(server_ref, &1, opts))

      {:ok,
       %{
         added_tools: Enum.map(to_add, &tool_name/1),
         removed_tools: Enum.map(to_remove, &tool_name/1),
         add_results: added_results,
         remove_results: removed_results
       }}
    end
  end

  @spec configured_agent_created(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def configured_agent_created(attrs, opts \\ []) when is_map(attrs) do
    agent_module = Keyword.get(opts, :agent_module, Agent)

    with {:ok, agent} <- agent_module.create_agent(attrs),
         {:ok, runtime} <- patch_agent_runtime(nil, agent, opts) do
      {:ok, %{agent: agent, runtime: runtime}}
    end
  end

  @spec configured_agent_updated(integer(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def configured_agent_updated(id, attrs, opts \\ []) when is_integer(id) and is_map(attrs) do
    agent_module = Keyword.get(opts, :agent_module, Agent)
    existing = agent_module.get_agent!(id)

    with {:ok, updated} <- agent_module.update_agent(existing, attrs),
         {:ok, runtime} <- patch_agent_runtime(existing, updated, opts) do
      {:ok, %{agent: updated, runtime: runtime}}
    end
  end

  @spec configured_agent_deleted(integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def configured_agent_deleted(id, opts \\ []) when is_integer(id) do
    agent_module = Keyword.get(opts, :agent_module, Agent)
    agent = agent_module.get_agent!(id)

    case agent_module.delete_agent(agent) do
      {:ok, deleted} -> {:ok, %{agent: deleted, runtime: %{strategy: :drain_and_stop}}}
      other -> other
    end
  end

  @spec mcp_endpoint_updated(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def mcp_endpoint_updated(request, opts \\ []) when is_map(request) do
    with {:ok, endpoint} <- persist_mcp_endpoint_update(request, opts),
         {:ok, runtime} <- patch_mcp_endpoint_runtime(endpoint, opts) do
      {:ok, %{endpoint: endpoint, runtime: runtime}}
    end
  end

  defp persist_mcp_endpoint_update(request, opts) do
    mcp_module = Keyword.get(opts, :mcp_module, MCP)

    action = normalize_action(map_get(request, :action))

    case action do
      :create ->
        mcp_module.create_mcp_endpoint(map_get(request, :attrs, %{}))

      :update ->
        id = map_get(request, :id)
        endpoint = mcp_module.get_mcp_endpoint!(id)
        mcp_module.update_mcp_endpoint(endpoint, map_get(request, :attrs, %{}))

      :enable_predefined ->
        mcp_module.enable_predefined(map_get(request, :predefined_id))

      :delete ->
        id = map_get(request, :id)
        endpoint = mcp_module.get_mcp_endpoint!(id)

        case mcp_module.delete_mcp_endpoint(endpoint) do
          {:ok, deleted} -> {:ok, %{deleted | status: "disabled"}}
          other -> other
        end

      _ ->
        {:error, {:invalid_request, request}}
    end
  end

  defp patch_agent_runtime(previous, agent, opts) do
    server_manager = Keyword.get(opts, :server_manager_module, ServerManager)

    cond do
      previous != nil and no_runtime_change?(previous, agent) ->
        {:ok, %{strategy: :no_runtime_change}}

      agent.active != true ->
        _ = server_manager.stop_server(agent.id)
        {:ok, %{strategy: :drain_and_stop}}

      true ->
        {added, removed} = mcp_assignment_diff(previous, agent)

        with {:ok, %{server_ref: server_ref, runtime: runtime}} <-
               server_manager.sync_runtime(agent),
             {:ok, unsync_results} <- unsync_removed_endpoints(server_ref, removed, opts) do
          {:ok,
           %{
             strategy: :hot_runtime_patch,
             tools_runtime: map_get(runtime, :tools, %{}),
             mcp_runtime: map_get(runtime, :mcp, %{}),
             added_mcp_endpoint_ids: added,
             removed_mcp_endpoint_ids: removed,
             unsync_results: unsync_results
           }}
        end
    end
  end

  defp patch_mcp_endpoint_runtime(endpoint, opts) do
    agent_module = Keyword.get(opts, :agent_module, Agent)

    impacted_agents =
      agent_module.list_agents_with_mcp_endpoint(endpoint.id)
      |> Enum.filter(&(&1.active == true))

    status = endpoint.status || "disabled"

    with :ok <- apply_runtime_endpoint_update(endpoint, status, opts),
         {:ok, results} <- patch_impacted_agents(impacted_agents, endpoint.id, status, opts) do
      warnings =
        Enum.flat_map(results, fn
          {:ok, %{status: :warning} = warning} -> [warning]
          _ -> []
        end)

      {:ok,
       %{
         strategy: :hot_runtime_patch,
         endpoint_id: endpoint.id,
         endpoint_status: status,
         impacted_agent_ids: Enum.map(impacted_agents, & &1.id),
         warnings: warnings,
         results: results
       }}
    end
  end

  defp unsync_removed_endpoints(_server_ref, [], _opts), do: {:ok, []}

  defp unsync_removed_endpoints(server_ref, endpoint_ids, opts) do
    Enum.reduce_while(endpoint_ids, {:ok, []}, fn endpoint_id, {:ok, acc} ->
      case unsync_endpoint_for_agent(server_ref, endpoint_id, opts) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp mcp_assignment_diff(nil, agent),
    do: {agent.enabled_mcp_endpoint_ids || [], []}

  defp mcp_assignment_diff(previous, agent) do
    previous_ids = previous.enabled_mcp_endpoint_ids || []
    current_ids = agent.enabled_mcp_endpoint_ids || []
    {current_ids -- previous_ids, previous_ids -- current_ids}
  end

  defp no_runtime_change?(previous, current) do
    fields = [
      :model,
      :credential_id,
      :enabled_tool_keys,
      :enabled_mcp_endpoint_ids,
      :advanced_options,
      :active,
      :job,
      :strategy
    ]

    Enum.all?(fields, fn field -> Map.get(previous, field) == Map.get(current, field) end)
  end

  defp apply_runtime_endpoint_update(_endpoint, _status, _opts) do
    # Endpoint lifecycle (register/refresh/unregister) is now handled
    # per-agent via signals in sync_endpoint_for_agent / unsync_endpoint_for_agent.
    :ok
  end

  defp patch_impacted_agent(agent, endpoint_id, status, opts) do
    server_manager = Keyword.get(opts, :server_manager_module, ServerManager)

    with {:ok, %{server_ref: server_ref, runtime: runtime}} <- server_manager.sync_runtime(agent) do
      if status == "enabled" do
        {:ok, endpoint_runtime_result(runtime, endpoint_id)}
      else
        unsync_endpoint_for_agent(server_ref, endpoint_id, opts)
      end
    end
  end

  defp endpoint_runtime_result(runtime, endpoint_id) when is_map(runtime) do
    runtime
    |> map_get(:mcp, %{})
    |> map_get(:results, [])
    |> Enum.find(%{endpoint_id: endpoint_id, status: :ok}, fn result ->
      map_get(result, :endpoint_id, nil) == endpoint_id
    end)
  end

  defp patch_impacted_agents(agents, endpoint_id, status, opts) do
    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, acc} ->
      case patch_impacted_agent(agent, endpoint_id, status, opts) do
        {:ok, result} -> {:cont, {:ok, [{:ok, result} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp sync_added_endpoint(server_ref, endpoint_id, opts, mcp_module) do
    case mcp_module.get_mcp_endpoint(endpoint_id) do
      %{status: "enabled"} = endpoint ->
        sync_enabled_endpoint(server_ref, endpoint, opts)

      nil ->
        {:ok, %{endpoint_id: endpoint_id, status: :skipped, reason: :endpoint_not_found}}

      _endpoint ->
        {:ok, %{endpoint_id: endpoint_id, status: :skipped, reason: :endpoint_disabled}}
    end
  end

  defp sync_enabled_endpoint(server_ref, endpoint, opts),
    do: sync_endpoint_for_agent(server_ref, endpoint, opts)

  defp sync_endpoint_for_agent(server_ref, endpoint, opts) do
    signal_adapter = Keyword.get(opts, :signal_adapter_module, SignalAdapter)

    with {:ok, runtime_endpoint_id} <- Runtime.runtime_endpoint_id(endpoint.id, opts),
         {:ok, endpoint_attrs} <- Runtime.build_endpoint_attrs(runtime_endpoint_id, endpoint),
         :ok <- signal_adapter.register_endpoint(server_ref, endpoint_attrs, opts),
         {:ok, result} <- signal_adapter.sync_tools(server_ref, runtime_endpoint_id, opts) do
      classify_sync_result(endpoint.id, result)
    end
  end

  defp unsync_endpoint_for_agent(server_ref, endpoint_id, opts) do
    signal_adapter = Keyword.get(opts, :signal_adapter_module, SignalAdapter)

    with {:ok, runtime_endpoint_id} <- Runtime.runtime_endpoint_id(endpoint_id, opts),
         {:ok, result} <- signal_adapter.unsync_tools(server_ref, runtime_endpoint_id, opts) do
      maybe_unregister_endpoint_globally(server_ref, runtime_endpoint_id, opts)
      classify_unsync_result(endpoint_id, result)
    end
  end

  defp maybe_unregister_endpoint_globally(server_ref, runtime_endpoint_id, opts) do
    signal_adapter = Keyword.get(opts, :signal_adapter_module, SignalAdapter)

    case ProxyRegistry.subscribers_for(runtime_endpoint_id) do
      [] -> signal_adapter.unregister_endpoint(server_ref, runtime_endpoint_id, opts)
      _ -> :ok
    end
  end

  defp classify_sync_result(endpoint_id, result) when is_map(result) do
    metrics_result = sync_metrics_from_result(result)

    case metrics_result do
      {:error, reason} ->
        {:error, {:mcp_sync_failed, %{endpoint_id: endpoint_id, reason: reason}}}

      {:ok,
       %{
         discovered_count: discovered_count,
         registered_count: registered_count,
         failed_count: failed_count
       } = metrics} ->
        cond do
          discovered_count == 0 ->
            {:ok,
             %{
               endpoint_id: endpoint_id,
               status: :warning,
               reason: :no_tools_discovered,
               discovered_count: discovered_count,
               registered_count: registered_count,
               failed_count: failed_count,
               result: result,
               metrics: metrics
             }}

          registered_count == 0 ->
            {:error,
             {:mcp_tools_not_registered,
              %{endpoint_id: endpoint_id, discovered_count: discovered_count, result: result}}}

          failed_count > 0 ->
            {:ok,
             %{
               endpoint_id: endpoint_id,
               status: :warning,
               reason: :partial_tool_sync,
               discovered_count: discovered_count,
               registered_count: registered_count,
               failed_count: failed_count,
               result: result,
               metrics: metrics
             }}

          true ->
            {:ok,
             %{
               endpoint_id: endpoint_id,
               status: :ok,
               discovered_count: discovered_count,
               registered_count: registered_count,
               failed_count: failed_count,
               result: result,
               metrics: metrics
             }}
        end
    end
  end

  defp classify_sync_result(endpoint_id, {:ok, result}) when is_map(result) do
    classify_sync_result(endpoint_id, result)
  end

  defp classify_sync_result(endpoint_id, {:error, reason}) do
    {:error, {:mcp_sync_failed, %{endpoint_id: endpoint_id, reason: reason}}}
  end

  defp classify_sync_result(endpoint_id, other) do
    {:error, {:invalid_mcp_sync_result, %{endpoint_id: endpoint_id, result: other}}}
  end

  defp classify_unsync_result(endpoint_id, %{status: :error} = result) do
    {:error, {:mcp_unsync_failed, %{endpoint_id: endpoint_id, result: result}}}
  end

  defp classify_unsync_result(_endpoint_id, result) when is_map(result), do: {:ok, result}

  defp classify_unsync_result(endpoint_id, {:ok, result}) when is_map(result) do
    classify_unsync_result(endpoint_id, result)
  end

  defp classify_unsync_result(endpoint_id, {:error, reason}) do
    {:error, {:mcp_unsync_failed, %{endpoint_id: endpoint_id, reason: reason}}}
  end

  defp classify_unsync_result(endpoint_id, other) do
    {:error, {:invalid_mcp_unsync_result, %{endpoint_id: endpoint_id, result: other}}}
  end

  defp sync_metrics_from_result(%{results: results}) when is_list(results) do
    Enum.reduce_while(
      results,
      {:ok, %{discovered_count: 0, registered_count: 0, failed_count: 0}},
      fn entry, {:ok, acc} ->
        case sync_metrics_from_entry(entry) do
          {:ok, metrics} ->
            {:cont,
             {:ok,
              %{
                discovered_count: acc.discovered_count + metrics.discovered_count,
                registered_count: acc.registered_count + metrics.registered_count,
                failed_count: acc.failed_count + metrics.failed_count
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  defp sync_metrics_from_result(result) when is_map(result) do
    {:ok,
     %{
       discovered_count: map_get_int(result, :discovered_count),
       registered_count: map_get_int(result, :registered_count),
       failed_count: map_get_int(result, :failed_count)
     }}
  end

  defp sync_metrics_from_entry(%{status: :error, reason: reason}), do: {:error, reason}

  defp sync_metrics_from_entry(%{status: :ok, result: result}) when is_map(result) do
    {:ok,
     %{
       discovered_count: map_get_int(result, :discovered_count),
       registered_count: map_get_int(result, :registered_count),
       failed_count: map_get_int(result, :failed_count)
     }}
  end

  defp sync_metrics_from_entry(other), do: {:error, {:invalid_sync_entry, other}}

  defp map_get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_get_int(map, key) when is_map(map) do
    case map_get(map, key, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp normalize_action(action) when is_atom(action), do: action

  defp normalize_action(action) when is_binary(action) do
    case action do
      "create" -> :create
      "update" -> :update
      "enable_predefined" -> :enable_predefined
      "delete" -> :delete
      _ -> :invalid
    end
  end

  defp normalize_action(_), do: :invalid

  defp list_tools(server_ref, opts) do
    list_tools_fn = Keyword.get(opts, :list_tools_fn, &Jido.AI.list_tools/1)

    case list_tools_fn.(server_ref) do
      {:ok, tools} when is_list(tools) -> {:ok, tools}
      tools when is_list(tools) -> {:ok, tools}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_list_tools_response, other}}
    end
  end

  defp register_tool(server_ref, tool_module, opts) do
    register_tool_fn = Keyword.get(opts, :register_tool_fn, &Jido.AI.register_tool/2)
    register_tool_fn.(server_ref, tool_module)
  end

  defp unregister_tool(server_ref, tool_module, opts) do
    unregister_tool_fn = Keyword.get(opts, :unregister_tool_fn, &Jido.AI.unregister_tool/2)
    unregister_tool_fn.(server_ref, tool_name(tool_module))
  end

  defp tool_name(tool_module) when is_atom(tool_module), do: tool_module.name()

  defp managed_tool_modules do
    Registry.tools()
    |> Enum.map(& &1.module)
    |> MapSet.new()
  end
end
