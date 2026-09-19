defmodule Zaq.Agent.ServerManager do
  @moduledoc """
  Lifecycle manager for long-lived Jido AgentServer processes.

  This module owns server process orchestration for configured agents, keyed by
  a caller-provided `server_id` scope (for example per conversation, person, or
  channel identity).

  Key concerns handled here:

  - Actor-bound ensure/create semantics (`ensure_server/4`) with fingerprint-based
    reuse or replacement, only after stable identity matches the live binding.
  - Initial spawn wiring through `Zaq.Agent.Factory` +
    `Zaq.Agent.ProviderSpec` (model spec, runtime config, initial context).
  - Runtime hydration and refresh of tools/MCP assignments via
    `Zaq.Agent.RuntimeSync`.
  - Runtime reconciliation for existing tracked servers (`sync_runtime/1`),
    including lazy restart behavior when fingerprint-relevant settings change.
  - Graceful/forced draining and stop semantics for in-flight requests.
  - Internal tracking of server ownership, monitors, and cleanup on process down.

  Interaction boundaries:

  - Used by `Zaq.Agent.Executor` to obtain a server reference before execution.
  - Uses `Factory.runtime_config/2` and `Factory.build_initial_context/3` to
    initialize agent state.
  - Uses `ProviderSpec.build/1` as the single source of provider/model runtime
    spec assembly.
  - Uses `RuntimeSync.sync_agent_runtime/3` to apply/update runtime tool and MCP
    state on live servers.

  The manager keeps minimal state required for lifecycle tracking and delegates
  behavior-specific runtime mutations to dedicated modules.
  """

  use GenServer

  require Logger

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.{ConfiguredAgent, Factory, OpaqueAliases, ProviderSpec, RuntimeSync}
  alias Zaq.Identity.ExecutionActor

  @dynamic_supervisor Zaq.Agent.AgentServerSupervisor
  @lifecycle_call_timeout 60_000
  @jido_instance Zaq.Agent.Jido
  @jido_registry Jido.registry_name(@jido_instance)

  @type state :: %{
          fingerprints: %{optional(String.t()) => binary()},
          agent_servers: %{optional(integer()) => MapSet.t(String.t())},
          server_to_agent: %{optional(String.t()) => integer()},
          credential_dependencies: %{optional(String.t()) => map()},
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

  1. Stops fingerprint-stale servers for lazy recreation on the next actor-bound ensure.
  2. Re-hydrates runtime state (configured tools + MCP assignments).

  ## Field update behavior (as implemented today)

  These behaviors are evaluated through `RuntimeSync.configured_agent_updated/3` and
  `RuntimeSync.no_runtime_change?/2` plus this module's `fingerprint/1`.

  - `:name`, `:description` -> no runtime effect (`:no_runtime_change`).

  - `:job`, `:enabled_tool_keys`, `:enabled_mcp_endpoint_ids` -> hot runtime patch only;
    no restart because these fields are runtime-tracked but are not part of the
    server fingerprint.

  - `:model`, `:credential_id`, `:strategy`,
    `:advanced_options`, `:idle_time_seconds`, `:model_max_context_tokens` -> forced shutdown for tracked servers -
    Lazy restart will carry new settings, because these fields are both
    runtime-tracked and part of the fingerprint.

  - `:active` -> when `false`, does not call `sync_runtime/1`; servers are drained/stopped
    by `RuntimeSync` (`:drain_and_stop`).

  - `:conversation_enabled` -> conversation-channel routing flag only; no runtime patch and
    no server restart.
  """
  def sync_runtime(%ConfiguredAgent{} = configured_agent) do
    GenServer.call(__MODULE__, {:sync_runtime, configured_agent}, @lifecycle_call_timeout)
  end

  @spec ensure_server(ConfiguredAgent.t(), String.t(), AIContext.t() | nil) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_server(%ConfiguredAgent{} = configured_agent, server_id, context \\ nil)
      when is_binary(server_id) and (is_nil(context) or is_struct(context, AIContext)) do
    ensure_server(configured_agent, server_id, context, [])
  end

  @doc """
  Ensures a scoped runtime bound to the explicit `:actor` option.

  Scope is opaque routing data, never identity. Legacy arities return
  `:missing_execution_actor` rather than raising or starting an unbound server.
  A live runtime's immutable `execution_actor` must match before touch or replacement;
  request tool context and mutable actor metadata do not establish that binding.
  """
  @spec ensure_server(ConfiguredAgent.t(), String.t(), AIContext.t() | nil, keyword()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_server(%ConfiguredAgent{} = configured_agent, server_id, context, opts)
      when is_binary(server_id) and (is_nil(context) or is_struct(context, AIContext)) and
             is_list(opts) do
    GenServer.call(
      __MODULE__,
      {:ensure_server, configured_agent, server_id, context, opts},
      @lifecycle_call_timeout
    )
  end

  @spec stop_server(ConfiguredAgent.t()) :: :ok
  def stop_server(%ConfiguredAgent{} = configured_agent) do
    GenServer.call(__MODULE__, {:stop_server, configured_agent}, @lifecycle_call_timeout)
  end

  @spec stop_server(ConfiguredAgent.t(), String.t()) :: :ok
  def stop_server(%ConfiguredAgent{} = configured_agent, server_id) do
    GenServer.call(
      __MODULE__,
      {:stop_server, configured_agent, server_id},
      @lifecycle_call_timeout
    )
  end

  @doc """
  Synchronously fences and begins stopping servers affected by a Connect mutation.

  Person grant mutations match the effective Person and credential, including
  runtimes using the org fallback. Credential and non-Person grant mutations
  conservatively match every runtime depending on the credential.
  """
  @spec invalidate_credential(map()) :: :ok
  def invalidate_credential(notification) when is_map(notification) do
    GenServer.call(
      __MODULE__,
      {:invalidate_credential, notification},
      @lifecycle_call_timeout
    )
  end

  @impl true
  def init(_opts) do
    stop_surviving_servers()

    {:ok,
     %{
       fingerprints: %{},
       agent_servers: %{},
       server_to_agent: %{},
       credential_dependencies: %{},
       draining: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call(
        {:ensure_server, %ConfiguredAgent{}, _server_id},
        _from,
        state
      ) do
    {:reply, {:error, :missing_execution_actor}, state}
  end

  def handle_call(
        {:ensure_server, %ConfiguredAgent{}, _server_id, _context},
        _from,
        state
      ) do
    {:reply, {:error, :missing_execution_actor}, state}
  end

  def handle_call(
        {:ensure_server, %ConfiguredAgent{} = configured_agent, server_id, context, opts},
        _from,
        state
      ) do
    result =
      with {:ok, actor} <- ExecutionActor.validate(Keyword.get(opts, :actor)),
           :ok <- validate_binding(safe_whereis(server_id), actor) do
        next_state = clear_stale_drain(state, server_id)

        if draining?(next_state, server_id) do
          {:error, :server_draining, next_state}
        else
          do_ensure_server(configured_agent, next_state, server_id, context, actor, opts)
        end
      end

    case result do
      {:ok, server_id, next_state} ->
        {:reply, {:ok, server_ref(server_id)}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

  def handle_call({:invalidate_credential, notification}, _from, state) do
    next_state =
      state
      |> Map.get(:credential_dependencies, %{})
      |> Enum.reduce(state, fn {server_id, dependency}, acc_state ->
        if affected_dependency?(dependency, notification),
          do: begin_stop(acc_state, server_id),
          else: acc_state
      end)

    {:reply, :ok, next_state}
  end

  # A supplied `context` (caller-built `Jido.AI.Context`) is consumed only when a
  # server is cold-started below — a warm/reused server keeps the context it spawned
  # with. This is exactly right for `run_agent`: each step derives a unique per-step
  # scope, so its first (and only) ask always cold-starts with the fresh context.
  defp do_ensure_server(
         %ConfiguredAgent{} = configured_agent,
         state,
         server_id,
         context,
         actor,
         opts
       ) do
    fingerprint = fingerprint(configured_agent)

    case {Map.get(state.fingerprints, server_id), safe_whereis(server_id)} do
      {^fingerprint, pid} when is_pid(pid) ->
        _ = Jido.AgentServer.touch(pid)
        {:ok, server_id, track_server(state, configured_agent.id, server_id)}

      {_previous, pid} when is_pid(pid) ->
        _ = stop_server_if_running(server_id)
        start_server(configured_agent, server_id, state, fingerprint, context, actor, opts)

      _ ->
        start_server(configured_agent, server_id, state, fingerprint, context, actor, opts)
    end
  end

  defp start_server(
         %ConfiguredAgent{} = configured_agent,
         server_id,
         state,
         fingerprint,
         context,
         actor,
         opts
       ) do
    case spawn_agent_server(configured_agent, server_id, context, actor, opts) do
      {:ok, credential_dependency} ->
        _ = hydrate_mcp_assignments(configured_agent, server_id)

        next_state =
          state
          |> put_in([:fingerprints, server_id], fingerprint)
          |> track_server(configured_agent.id, server_id, credential_dependency)
          |> monitor_server(server_id)
          |> schedule_authentication_expiry(server_id, credential_dependency)

        {:ok, server_id, next_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def handle_info({:expire_server, server_id}, state) do
    _ = stop_server_if_running(server_id)
    OpaqueAliases.clear_scope(server_id)
    {:noreply, untrack_server(state, server_id)}
  end

  def handle_info({:expire_authentication, server_id, expected_pid}, state) do
    dependency = Map.get(state.credential_dependencies, server_id)

    cond do
      safe_whereis(server_id) != expected_pid ->
        {:noreply, state}

      authentication_expired?(dependency) ->
        {:noreply, begin_stop(state, server_id)}

      true ->
        {:noreply, schedule_authentication_expiry(state, server_id, dependency)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_sid, r} -> r == ref end) do
      nil ->
        {:noreply, state}

      {server_id, _ref} ->
        OpaqueAliases.clear_scope(server_id)
        {:noreply, untrack_server(state, server_id)}
    end
  end

  def handle_info({:force_stop_server, server_id, ref}, state) do
    case Map.get(state.draining, server_id) do
      ^ref ->
        _ = stop_server_if_running(server_id)
        OpaqueAliases.clear_scope(server_id)
        {:noreply, state |> untrack_server(server_id) |> clear_drain(server_id)}

      _ ->
        {:noreply, state}
    end
  end

  defp spawn_agent_server(%ConfiguredAgent{} = configured_agent, server_id, context, actor, opts) do
    with {:ok, model_spec} <- ProviderSpec.build(configured_agent),
         {:ok, runtime_config} <-
           Factory.runtime_config(
             configured_agent,
             opts |> Keyword.take([:connect_module]) |> Keyword.put(:actor, actor)
           ),
         :ok <-
           spawn_server(server_id, configured_agent, %{
             model: model_spec,
             runtime_config: runtime_config,
             execution_actor: actor,
             tool_context:
               Map.merge(runtime_config.tool_context, %{
                 configured_agent_id: configured_agent.id,
                 opaque_alias_scope: server_id
               }),
             context: Factory.build_initial_context(configured_agent, server_id, context)
           }) do
      {:ok, Map.get(runtime_config, :credential_dependency)}
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

      {:error, {:already_started, pid}} ->
        validate_binding(pid, initial_state.execution_actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_binding(nil, _actor), do: :ok

  defp validate_binding(pid, actor) do
    with {:ok, %{raw_state: raw_state}} <- Jido.AgentServer.status(pid),
         {:ok, bound_identity} <- ExecutionActor.identity(Map.get(raw_state, :execution_actor)),
         {:ok, identity} <- ExecutionActor.identity(actor) do
      if identity == bound_identity, do: :ok, else: {:error, :execution_actor_mismatch}
    else
      {:error, reason} when reason in [:missing_execution_actor, :invalid_execution_actor] ->
        {:error, reason}

      _ ->
        {:error, :missing_execution_actor}
    end
  rescue
    _ -> {:error, :missing_execution_actor}
  catch
    :exit, _ -> {:error, :missing_execution_actor}
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
        monitor_ref = Process.monitor(pid)

        case DynamicSupervisor.terminate_child(@dynamic_supervisor, pid) do
          :ok ->
            await_process_down(pid, monitor_ref)

          {:error, _reason} ->
            force_kill_if_alive(pid)
            await_process_down(pid, monitor_ref)
        end

      _ ->
        :ok
    end
  end

  defp await_process_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      500 ->
        force_kill_if_alive(pid)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          500 ->
            Process.demonitor(monitor_ref, [:flush])
            :ok
        end
    end
  end

  defp force_kill_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  defp safe_whereis(server_id) do
    # Registry lookup can race with shutdown during replacement windows.
    case Jido.AgentServer.whereis(@jido_registry, server_id) do
      pid when is_pid(pid) -> if(Process.alive?(pid), do: pid)
      _ -> nil
    end
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
      configured_agent.model_max_context_tokens
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

  defp schedule_authentication_expiry(state, _server_id, nil), do: state

  defp schedule_authentication_expiry(state, server_id, %{expires_at: %DateTime{} = expires_at}) do
    case safe_whereis(server_id) do
      pid when is_pid(pid) ->
        delay = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0)
        _ = Process.send_after(self(), {:expire_authentication, server_id, pid}, delay)
        state

      _ ->
        state
    end
  end

  defp schedule_authentication_expiry(state, _server_id, _dependency), do: state

  defp authentication_expired?(%{expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp authentication_expired?(_), do: false

  defp stop_surviving_servers do
    @dynamic_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        stop_surviving_server(pid)

      _ ->
        :ok
    end)
  catch
    :exit, _ -> :ok
  end

  defp stop_surviving_server(pid) do
    monitor_ref = Process.monitor(pid)

    case DynamicSupervisor.terminate_child(@dynamic_supervisor, pid) do
      :ok -> :ok
      {:error, _} -> force_kill_if_alive(pid)
    end

    await_process_down(pid, monitor_ref)
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

  defp affected_dependency?(nil, _notification), do: false

  defp affected_dependency?(dependency, notification) do
    credential_id = event_value(notification, "credential_id")
    owner_type = event_value(notification, "owner_type")
    owner_id = event_value(notification, "owner_id")

    dependency.credential_id == credential_id and
      (owner_type != "person" or dependency.effective_person_id == owner_id)
  end

  defp event_value(event, key), do: Map.get(event, key) || Map.get(event, String.to_atom(key))

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

  defp track_server(state, agent_id, server_id, credential_dependency) do
    state
    |> track_server(agent_id, server_id)
    |> Map.update(
      :credential_dependencies,
      %{server_id => credential_dependency},
      &Map.put(&1, server_id, credential_dependency)
    )
  end

  defp untrack_server(state, server_id) do
    state = demonitor_server(state, server_id)
    agent_id = Map.get(state.server_to_agent, server_id)

    state =
      %{
        state
        | fingerprints: Map.delete(state.fingerprints, server_id),
          server_to_agent: Map.delete(state.server_to_agent, server_id),
          draining: Map.delete(state.draining, server_id)
      }
      |> delete_credential_dependency(server_id)

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

  defp delete_credential_dependency(state, server_id) do
    Map.put(
      state,
      :credential_dependencies,
      state |> Map.get(:credential_dependencies, %{}) |> Map.delete(server_id)
    )
  end

  defp tracked_server_ids(state, agent_id) do
    state.agent_servers
    |> Map.get(agent_id, MapSet.new())
    |> MapSet.to_list()
  end
end
