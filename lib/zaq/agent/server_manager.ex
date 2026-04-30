defmodule Zaq.Agent.ServerManager do
  @moduledoc """
  Starts and maintains one long-lived AgentServer per configured agent scope.

  The scope is determined upstream and passed in as a `server_id` string — it
  can represent any granularity (agent-wide, per-person, per-channel, etc.).
  """

  use GenServer

  require Logger

  alias Zaq.Agent.{ConfiguredAgent, Factory, ProviderSpec, RuntimeSync}

  @dynamic_supervisor Zaq.Agent.AgentServerSupervisor
  @jido_instance Zaq.Agent.Jido
  @jido_registry Jido.registry_name(@jido_instance)

  @type state :: %{
          fingerprints: %{optional(String.t()) => binary()},
          agent_servers: %{optional(integer()) => MapSet.t(String.t())},
          server_to_agent: %{optional(String.t()) => integer()},
          draining: %{optional(String.t()) => reference()},
          monitors: %{optional(String.t()) => reference()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec sync_runtime(ConfiguredAgent.t()) :: {:ok, map()} | {:error, term()}
  @doc """
  Reconciles tracked runtime servers for a configured agent.

  For each tracked `server_id`, this function:

  1. Ensures a live server exists for the current config (`do_ensure_server/3`).
  2. Re-hydrates runtime state (configured tools + MCP assignments).

  ## Field update behavior (as implemented today)

  These behaviors are evaluated through `RuntimeSync.configured_agent_updated/3` and
  `RuntimeSync.no_runtime_change?/2` plus this module's `fingerprint/1`.

  - `:name`, `:description` -> no runtime effect (`:no_runtime_change`).

  - `:job`, `:enabled_tool_keys`, `:enabled_mcp_endpoint_ids` -> hot runtime patch only;
    no restart because these fields are runtime-tracked but are not part of the
    server fingerprint.

  - `:model`, `:credential_id`, `:strategy`,
    `:advanced_options`, `:idle_time_seconds`, `:memory_context_max_size` -> forced shutdown for tracked servers -
    Lazy restart will carry new settings, because these fields are both
    runtime-tracked and part of the fingerprint.

  - `:active` -> when `false`, does not call `sync_runtime/1`; servers are drained/stopped
    by `RuntimeSync` (`:drain_and_stop`).

  - `:conversation_enabled` -> conversation-channel routing flag only; no runtime patch and
    no server restart.
  """
  def sync_runtime(%ConfiguredAgent{} = configured_agent) do
    GenServer.call(__MODULE__, {:sync_runtime, configured_agent})
  end

  @spec ensure_server(ConfiguredAgent.t(), String.t()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_server(%ConfiguredAgent{} = configured_agent, server_id)
      when is_binary(server_id) do
    GenServer.call(__MODULE__, {:ensure_server, configured_agent, server_id})
  end

  @spec stop_server(ConfiguredAgent.t()) :: :ok
  def stop_server(%ConfiguredAgent{} = configured_agent) do
    GenServer.call(__MODULE__, {:stop_server, configured_agent})
  end

  @spec stop_server(ConfiguredAgent.t(), String.t()) :: :ok
  def stop_server(%ConfiguredAgent{} = configured_agent, server_id) do
    GenServer.call(__MODULE__, {:stop_server, configured_agent, server_id})
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{fingerprints: %{}, agent_servers: %{}, server_to_agent: %{}, draining: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call(
        {:ensure_server, %ConfiguredAgent{} = configured_agent, server_id},
        _from,
        state
      ) do
    state = clear_stale_drain(state, server_id)

    case do_ensure_server(configured_agent, state, server_id) do
      {:ok, server_id, next_state} ->
        {:reply, {:ok, server_ref(server_id)}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:sync_runtime, %ConfiguredAgent{} = configured_agent}, _from, state) do
    case do_sync_runtime(configured_agent, state) do
      {:ok, response, next_state} -> {:reply, {:ok, response}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:stop_server, %ConfiguredAgent{} = configured_agent}, _from, state) do
    next_state =
      Enum.reduce(tracked_server_ids(state, configured_agent.id), state, fn server_id,
                                                                            acc_state ->
        begin_stop(acc_state, server_id)
      end)

    {:reply, :ok, next_state}
  end

  def handle_call({:stop_server, %ConfiguredAgent{} = configured_agent, server_id}, _from, state) do
    next_state =
      Enum.reduce(tracked_server_ids(state, configured_agent.id), state, fn tracked_server_id,
                                                                            acc_state ->
        if tracked_server_id == server_id do
          begin_stop(acc_state, tracked_server_id)
        else
          acc_state
        end
      end)

    {:reply, :ok, next_state}
  end

  defp do_ensure_server(%ConfiguredAgent{} = configured_agent, state, server_id) do
    fingerprint = fingerprint(configured_agent)

    case {Map.get(state.fingerprints, server_id), safe_whereis(server_id)} do
      {^fingerprint, pid} when is_pid(pid) ->
        _ = Jido.AgentServer.touch(pid)
        {:ok, server_id, track_server(state, configured_agent.id, server_id)}

      {_previous, pid} when is_pid(pid) ->
        _ = stop_server_if_running(server_id)
        start_server(configured_agent, server_id, state, fingerprint)

      _ ->
        start_server(configured_agent, server_id, state, fingerprint)
    end
  end

  defp start_server(
         %ConfiguredAgent{} = configured_agent,
         server_id,
         state,
         fingerprint
       ) do
    case spawn_agent_server(configured_agent, server_id) do
      :ok ->
        _ = hydrate_mcp_assignments(configured_agent, server_id)

        next_state =
          state
          |> put_in([:fingerprints, server_id], fingerprint)
          |> track_server(configured_agent.id, server_id)
          |> monitor_server(server_id)

        {:ok, server_id, next_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def handle_info({:expire_server, server_id}, state) do
    _ = stop_server_if_running(server_id)
    {:noreply, untrack_server(state, server_id)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_sid, r} -> r == ref end) do
      nil ->
        {:noreply, state}

      {server_id, _ref} ->
        {:noreply, untrack_server(state, server_id)}
    end
  end

  def handle_info({:force_stop_server, server_id, ref}, state) do
    case Map.get(state.draining, server_id) do
      ^ref ->
        _ = stop_server_if_running(server_id)
        {:noreply, state |> untrack_server(server_id) |> clear_drain(server_id)}

      _ ->
        {:noreply, state}
    end
  end

  defp spawn_agent_server(%ConfiguredAgent{} = configured_agent, server_id) do
    with {:ok, model_spec} <- ProviderSpec.build(configured_agent),
         {:ok, runtime_config} <- Factory.runtime_config(configured_agent) do
      spawn_server(server_id, configured_agent, %{
        model: model_spec,
        runtime_config: runtime_config,
        tool_context: %{configured_agent_id: configured_agent.id},
        context: Factory.build_initial_context(configured_agent, server_id)
      })
    end
  end

  defp spawn_server(server_id, configured_agent, initial_state) do
    case DynamicSupervisor.start_child(
           @dynamic_supervisor,
           {Jido.AgentServer,
            [
              agent: Factory,
              jido: @jido_instance,
              registry: @jido_registry,
              id: server_id,
              initial_state: initial_state,
              lifecycle_mod: Zaq.Agent.IdleLifecycle,
              idle_timeout: agent_idle_ttl_ms(configured_agent)
            ]}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hydrate_mcp_assignments(%ConfiguredAgent{} = configured_agent, server_id) do
    server_ref = server_ref(server_id)

    case runtime_sync_module().sync_agent_runtime(
           configured_agent,
           server_ref,
           runtime_sync_opts()
         ) do
      {:ok, %{mcp: %{warnings: []}} = runtime} ->
        {:ok, runtime}

      {:ok, %{mcp: %{warnings: warnings}} = runtime} ->
        Logger.warning(
          "MCP tool hydration warnings for configured agent #{configured_agent.id}: #{inspect(warnings)}"
        )

        {:ok, runtime}

      {:ok, other} ->
        Logger.warning(
          "Unexpected MCP hydration result for configured agent #{configured_agent.id}: #{inspect(other)}"
        )

        {:ok, other}

      {:error, reason} ->
        Logger.warning(
          "Failed to hydrate MCP tools for configured agent #{configured_agent.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp stop_server_if_running(server_id) do
    # Server shutdown is immediate here; graceful drain is coordinated by begin_stop/2.
    case safe_whereis(server_id) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)

      _ ->
        :ok
    end
  end

  defp safe_whereis(server_id) do
    # Registry lookup can race with shutdown during replacement windows.
    Jido.AgentServer.whereis(@jido_registry, server_id)
  rescue
    ArgumentError ->
      Logger.warning("Jido registry #{@jido_registry} is not available yet")
      nil
  end

  defp server_ref(server_id) when is_binary(server_id) do
    Jido.AgentServer.via_tuple(server_id, @jido_registry)
  end

  defp fingerprint(%ConfiguredAgent{} = configured_agent) do
    :erlang.phash2({
      configured_agent.model,
      configured_agent.credential_id,
      configured_agent.strategy,
      configured_agent.advanced_options,
      configured_agent.active,
      configured_agent.idle_time_seconds,
      configured_agent.memory_context_max_size
    })
    |> Integer.to_string()
  end

  defp runtime_sync_module do
    Application.get_env(:zaq, :agent_runtime_sync_module, RuntimeSync)
  end

  defp runtime_sync_opts do
    case Application.get_env(:zaq, :agent_runtime_sync_opts, []) do
      opts when is_list(opts) -> opts
      _ -> []
    end
  end

  defp monitor_server(state, server_id) do
    state = demonitor_server(state, server_id)

    case safe_whereis(server_id) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        put_in(state, [:monitors, server_id], ref)

      _ ->
        state
    end
  end

  defp demonitor_server(state, server_id) do
    case Map.get(state.monitors, server_id) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])
        Map.update!(state, :monitors, &Map.delete(&1, server_id))
    end
  end

  defp agent_idle_ttl_ms(%ConfiguredAgent{idle_time_seconds: s}) when is_integer(s) and s > 0,
    do: s * 1_000

  defp agent_idle_ttl_ms(_),
    do: Application.get_env(:zaq, :agent_server_idle_ttl_ms, 1_800_000)

  defp drain_timeout_ms do
    Application.get_env(:zaq, :agent_server_drain_timeout_ms, 1_500)
  end

  defp force_drain_enabled? do
    Application.get_env(:zaq, :agent_server_force_drain, false) == true
  end

  defp begin_stop(state, server_id) do
    cond do
      not server_running?(server_id) ->
        untrack_server(state, server_id)

      draining?(state, server_id) ->
        state

      force_drain_enabled?() ->
        ref = make_ref()
        _ = Process.send_after(self(), {:force_stop_server, server_id, ref}, drain_timeout_ms())
        %{state | draining: Map.put(state.draining, server_id, ref)}

      in_flight_requests?(server_id) ->
        ref = make_ref()
        _ = Process.send_after(self(), {:force_stop_server, server_id, ref}, drain_timeout_ms())
        %{state | draining: Map.put(state.draining, server_id, ref)}

      true ->
        _ = stop_server_if_running(server_id)
        untrack_server(state, server_id)
    end
  end

  defp draining?(state, server_id), do: Map.has_key?(state.draining, server_id)

  defp clear_drain(state, server_id),
    do: %{state | draining: Map.delete(state.draining, server_id)}

  defp clear_stale_drain(state, server_id) do
    if draining?(state, server_id) and not server_running?(server_id) do
      clear_drain(state, server_id)
    else
      state
    end
  end

  defp server_running?(server_id) do
    case safe_whereis(server_id) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  end

  defp in_flight_requests?(server_id) do
    case Jido.AgentServer.status(server_ref(server_id)) do
      {:ok, %{raw_state: %{requests: requests}}} when is_map(requests) -> map_size(requests) > 0
      _ -> false
    end
  rescue
    _ -> false
  end

  defp do_sync_runtime(configured_agent, state) do
    case tracked_server_ids(state, configured_agent.id) do
      [] ->
        {:ok,
         %{runtime: %{strategy: :no_running_servers}, synced_servers: [], stopped_server_ids: []},
         state}

      server_ids ->
        sync_existing_servers(configured_agent, state, server_ids)
    end
  end

  defp sync_existing_servers(configured_agent, state, server_ids) do
    expected_fingerprint = fingerprint(configured_agent)

    sync_result =
      Enum.reduce_while(server_ids, {:ok, state, []}, fn server_id, {:ok, acc_state, acc} ->
        case sync_single_runtime(configured_agent, acc_state, server_id, expected_fingerprint) do
          {:ok, response, next_state} ->
            synced_server = %{
              server_id: server_id,
              server_ref: response.server_ref,
              runtime: response.runtime
            }

            {:cont, {:ok, next_state, [synced_server | acc]}}

          {:stopped, stopped_server_id, next_state} ->
            stopped = %{server_id: stopped_server_id, status: :stopped_pending_lazy_restart}
            {:cont, {:ok, next_state, [stopped | acc]}}

          {:stale, stale_server_id, next_state} ->
            stale = %{server_id: stale_server_id, status: :stale_untracked}
            {:cont, {:ok, next_state, [stale | acc]}}

          {:error, reason, next_state} ->
            {:halt, {:error, reason, next_state}}
        end
      end)

    case sync_result do
      {:ok, next_state, entries} ->
        synced_servers = Enum.filter(entries, &Map.has_key?(&1, :runtime))

        stopped_server_ids =
          entries
          |> Enum.filter(&(Map.get(&1, :status) == :stopped_pending_lazy_restart))
          |> Enum.map(& &1.server_id)
          |> Enum.reverse()

        case synced_servers do
          [first | _] ->
            {:ok,
             %{
               server_ref: first.server_ref,
               runtime: first.runtime,
               synced_servers: Enum.reverse(synced_servers),
               stopped_server_ids: stopped_server_ids
             }, next_state}

          [] ->
            {:ok,
             %{
               runtime: %{strategy: :stopped_pending_lazy_restart},
               synced_servers: [],
               stopped_server_ids: stopped_server_ids
             }, next_state}
        end

      {:error, reason, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp sync_single_runtime(configured_agent, state, server_id, expected_fingerprint) do
    current_fingerprint = Map.get(state.fingerprints, server_id)

    case safe_whereis(server_id) do
      pid when is_pid(pid) and current_fingerprint == expected_fingerprint ->
        case hydrate_mcp_assignments(configured_agent, server_id) do
          {:ok, runtime} ->
            {:ok, %{server_ref: server_ref(server_id), runtime: runtime}, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      pid when is_pid(pid) ->
        _ = stop_server_if_running(server_id)
        {:stopped, server_id, untrack_server(state, server_id)}

      _ ->
        {:stale, server_id, untrack_server(state, server_id)}
    end
  end

  defp track_server(state, agent_id, server_id) do
    agent_servers =
      Map.update(
        state.agent_servers,
        agent_id,
        MapSet.new([server_id]),
        &MapSet.put(&1, server_id)
      )

    %{
      state
      | agent_servers: agent_servers,
        server_to_agent: Map.put(state.server_to_agent, server_id, agent_id)
    }
  end

  defp untrack_server(state, server_id) do
    state = demonitor_server(state, server_id)
    agent_id = Map.get(state.server_to_agent, server_id)

    state = %{
      state
      | fingerprints: Map.delete(state.fingerprints, server_id),
        server_to_agent: Map.delete(state.server_to_agent, server_id),
        draining: Map.delete(state.draining, server_id)
    }

    case agent_id do
      nil ->
        state

      _ ->
        updated_set =
          state.agent_servers
          |> Map.get(agent_id, MapSet.new())
          |> MapSet.delete(server_id)

        agent_servers =
          if MapSet.size(updated_set) == 0 do
            Map.delete(state.agent_servers, agent_id)
          else
            Map.put(state.agent_servers, agent_id, updated_set)
          end

        %{state | agent_servers: agent_servers}
    end
  end

  defp tracked_server_ids(state, agent_id) do
    state.agent_servers
    |> Map.get(agent_id, MapSet.new())
    |> MapSet.to_list()
  end
end
