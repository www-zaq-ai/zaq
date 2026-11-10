defmodule Zaq.Agent.ServerManager do
  @moduledoc """
  Lifecycle manager for long-lived Jido AgentServer processes.

  This module owns server process orchestration for configured agents, keyed by
  a caller-provided opaque `server_id`. Persisted history selection is supplied
  separately as an explicit conversation binding.

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
  - Live incarnation snapshots and exact-PID history-lease request binding for
    native controls; no retained stream presentation or request archive.

  Interaction boundaries:

  - Used by `Zaq.Agent.Executor` to obtain a server reference before execution.
  - Uses `Factory.runtime_config/2` and `Factory.build_initial_context/4` to
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

  alias Zaq.Agent.{
    ConfiguredAgent,
    Factory,
    HistoryLifecycle,
    OpaqueAliases,
    ProviderSpec,
    RuntimeSync
  }

  alias Zaq.Identity.ExecutionActor

  @dynamic_supervisor Zaq.Agent.AgentServerSupervisor
  @lifecycle_call_timeout 60_000
  @jido_instance Zaq.Agent.Jido
  @jido_registry Jido.registry_name(@jido_instance)

  @type state :: %{
          optional(:drain_timeouts) => %{optional(String.t()) => non_neg_integer()},
          fingerprints: %{optional(String.t()) => binary()},
          agent_servers: %{optional(integer()) => MapSet.t(String.t())},
          server_to_agent: %{optional(String.t()) => integer()},
          runtime_bindings: %{optional(String.t()) => map()},
          credential_dependencies: %{optional(String.t()) => map()},
          draining: %{optional(String.t()) => reference()},
          monitors: %{optional(String.t()) => reference()},
          history: %{optional(String.t()) => map()}
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

  A custom `:config` provider resolves `:agent_server_drain_timeout_ms` at cold
  start. Its value belongs to that runtime incarnation and survives warm reuse
  and later credential-triggered stops. Without a custom provider, draining
  continues to read application configuration when shutdown begins.
  """
  @spec ensure_server(ConfiguredAgent.t(), String.t(), AIContext.t() | nil, keyword()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_server(%ConfiguredAgent{} = configured_agent, server_id, context, opts)
      when is_binary(server_id) and (is_nil(context) or is_struct(context, AIContext)) and
             is_list(opts) do
    deadline = System.monotonic_time(:millisecond) + @lifecycle_call_timeout
    ensure_server_until(configured_agent, server_id, context, opts, deadline)
  end

  defp ensure_server_until(configured_agent, server_id, context, opts, deadline) do
    case GenServer.call(
           __MODULE__,
           {:ensure_server, configured_agent, server_id, context, opts},
           @lifecycle_call_timeout
         ) do
      {:error, {:server_retiring, pid}} ->
        ref = Process.monitor(pid)
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} ->
            ensure_server_until(configured_agent, server_id, context, opts, deadline)
        after
          remaining ->
            Process.demonitor(ref, [:flush])
            {:error, :server_retiring}
        end

      other ->
        other
    end
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

  @doc "Stops a scoped runtime only when it is still the expected process incarnation."
  @spec stop_server_if_current(ConfiguredAgent.t(), String.t(), pid()) :: :ok
  def stop_server_if_current(%ConfiguredAgent{} = configured_agent, server_id, expected_pid)
      when is_binary(server_id) and is_pid(expected_pid) do
    GenServer.call(
      __MODULE__,
      {:stop_server_if_current, configured_agent, server_id, expected_pid},
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

  @doc "Returns the secret-free credential dependency for a running scoped runtime."
  @spec credential_dependency(String.t()) :: map() | nil
  def credential_dependency(server_id) when is_binary(server_id) do
    GenServer.call(__MODULE__, {:credential_dependency, server_id}, @lifecycle_call_timeout)
  end

  @doc "Snapshots tracked live incarnations, not retained requests; native reads happen outside the manager."
  @spec runtime_candidates(map(), String.t() | nil, term()) :: {:ok, list()} | {:error, term()}
  def runtime_candidates(actor, scope \\ nil, runtime \\ nil) do
    case ExecutionActor.identity(actor) do
      {:ok, _} -> GenServer.call(__MODULE__, {:runtime_candidates, actor, scope, runtime})
      _ -> {:error, :not_found}
    end
  end

  @doc "Binds the native request ID once to its process-owned completion lease."
  def bind_native_history_request(server_id, token, request_id),
    do: GenServer.call(__MODULE__, {:bind_native_history_request, server_id, token, request_id})

  @doc "Revalidates exact live targeting without resolving a reusable name in the control caller."
  def current_request_target(target),
    do: GenServer.call(__MODULE__, {:current_request_target, target})

  @doc "Claims exclusive history admission on an exact actor-bound runtime incarnation."
  def begin_history_request(server_id, pid, actor) when is_binary(server_id) and is_pid(pid),
    do: GenServer.call(__MODULE__, {:begin_history_request, server_id, pid, actor}, :infinity)

  @doc "Reserves the exact incarnation's next lease with a bounded live handoff deadline."
  @spec reserve_history_request(pid(), map(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def reserve_history_request(pid, actor, input_id, timeout \\ 60_000)
      when is_pid(pid) and is_binary(input_id) and is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + min(timeout, 60_000)

    GenServer.call(
      __MODULE__,
      {:reserve_history_request, pid, actor, input_id, deadline},
      :infinity
    )
  end

  @doc "Adopts this caller/session's reservation for the same input, without reacquiring its lease."
  @spec adopt_history_request(String.t(), pid(), reference(), map()) :: :ok | {:error, term()}
  def adopt_history_request(server_id, pid, token, details),
    do: GenServer.call(__MODULE__, {:adopt_history_request, server_id, pid, token, details})

  @doc "Publishes incorporated cursors only after the lease's idle context operation is confirmed."
  def complete_history_request(server_id, token, %AIContext{} = context, cursors),
    do:
      GenServer.call(
        __MODULE__,
        {:complete_history_request, server_id, token, context, cursors},
        @lifecycle_call_timeout
      )

  @doc "Binds an owned lease to an internal API completion session, never an outgoing payload."
  def bind_history_request(server_id, token, details),
    do: GenServer.call(__MODULE__, {:bind_history_request, server_id, token, details})

  @doc "Returns only this caller's leases belonging to its internal completion session."
  def history_requests(session), do: GenServer.call(__MODULE__, {:history_requests, session})

  @doc "Pins existing matching incarnations for a privately admitted caller/session."
  def pin_history_scope(transcript_id, actor, session),
    do: GenServer.call(__MODULE__, {:pin_history_scope, transcript_id, actor, session})

  @doc "Releases only this caller's pins, leaving native/root work and other waiters intact."
  def release_history_pins(session),
    do: GenServer.call(__MODULE__, {:release_history_pins, session})

  @doc "Checks a native target against this caller's existing admission pin during retirement."
  def admitted_history_target(pid, session),
    do: GenServer.call(__MODULE__, {:admitted_history_target, pid, session})

  @doc "Requests soft retirement from an Engine-verified effective history-access denial."
  def retire_history_scope(%{transcript_id: id, person_id: person_id})
      when is_binary(id) and is_integer(person_id),
      do: GenServer.call(__MODULE__, {:retire_history_scope, id, person_id})

  @doc "Reads or replaces bounded authorized history for an exact live lease, not inspection."
  def history_projection(history, actor, projection \\ nil)

  def history_projection(
        %{lease_ref: {server_id, pid, token}, binding: binding},
        actor,
        projection
      ),
      do:
        GenServer.call(
          __MODULE__,
          {:history_projection, server_id, pid, token, binding, actor, projection}
        )

  def history_projection(_history, _actor, _projection), do: {:error, :stale_history_lease}

  @doc "Disposes an owned lease and its exact runtime after an unhandled or failed outcome."
  def abort_history_request(server_id, token),
    do:
      GenServer.call(
        __MODULE__,
        {:abort_history_request, server_id, token},
        @lifecycle_call_timeout
      )

  @impl true
  def init(_opts) do
    stop_surviving_servers()

    {:ok,
     %{
       fingerprints: %{},
       agent_servers: %{},
       server_to_agent: %{},
       runtime_bindings: %{},
       credential_dependencies: %{},
       draining: %{},
       monitors: %{},
       history: %{}
     }}
  end

  @impl true
  def handle_call({:runtime_candidates, actor, scope, runtime}, _from, state) do
    {:ok, principal} = ExecutionActor.identity(actor)

    candidates =
      Enum.flat_map(state.runtime_bindings, fn entry ->
        snapshot_candidate(entry, state, principal, scope, runtime)
      end)

    {:reply, {:ok, candidates}, state}
  end

  def handle_call({:bind_native_history_request, id, token, request_id}, {owner, _}, state) do
    with {:ok, entry} <- HistoryLifecycle.owned_entry(state.history, id, token, owner),
         true <- is_binary(request_id),
         true <- is_nil(entry.lease[:request_id]) or entry.lease.request_id == request_id do
      entry = %{entry | lease: Map.put(entry.lease, :request_id, request_id)}
      {:reply, :ok, %{state | history: Map.put(state.history, id, entry)}}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :history_binding_conflict}, state}
    end
  end

  def handle_call({:current_request_target, target}, _from, state) do
    current? =
      Map.has_key?(state.server_to_agent, target.server_id) and
        safe_whereis(target.server_id) == target.runtime_pid and
        current_target_lease?(state.history[target.server_id], target)

    {:reply, if(current?, do: :ok, else: {:error, :stale_runtime}), state}
  end

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
        {owner, _},
        state
      ) do
    result =
      with {:ok, actor} <- ExecutionActor.validate(Keyword.get(opts, :actor)),
           :ok <- HistoryLifecycle.validate_initial(Keyword.get(opts, :history_cursors)),
           {:ok, history_binding} <- validate_history_binding(Keyword.get(opts, :history_binding)),
           :ok <- validate_binding(safe_whereis(server_id), actor, history_binding) do
        next_state = clear_stale_drain(state, server_id)
        opts = Keyword.put(opts, :history_binding, history_binding)

        cond do
          draining?(next_state, server_id) ->
            {:error, :server_draining, next_state}

          retiring_for_caller?(next_state, server_id, owner, opts[:history_session]) ->
            {:error, {:server_retiring, safe_whereis(server_id)}, next_state}

          true ->
            do_ensure_server(configured_agent, next_state, server_id, context, actor, opts)
        end
      end

    case result do
      {:ok, server_id, next_state} ->
        history =
          HistoryLifecycle.pin_runtime(
            next_state.history,
            server_id,
            owner,
            opts[:history_session]
          )

        next_state = %{next_state | history: history}
        {:reply, {:ok, server_ref(server_id)}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:begin_history_request, server_id, pid, actor}, from, state) do
    with :ok <- history_runtime_current(state, server_id, pid),
         :ok <- validate_history_actor(pid, actor) do
      case HistoryLifecycle.begin_request(state.history, server_id, pid, from) do
        {:reply, response, history} -> {:reply, response, %{state | history: history}}
        {:wait, history} -> {:noreply, %{state | history: history}}
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reserve_history_request, pid, actor, input_id, deadline}, from, state) do
    with {:ok, server_id} <- history_incarnation_id(state.history, pid),
         :ok <- history_runtime_current(state, server_id, pid),
         :ok <- validate_history_actor(pid, actor) do
      case HistoryLifecycle.begin_request(state.history, server_id, pid, from,
             deadline: deadline,
             input_id: input_id,
             reservation?: true
           ) do
        {:reply, {:ok, lease}, history} ->
          {:reply, {:ok, %{server_id: server_id, lease: lease}}, %{state | history: history}}

        {:reply, error, history} ->
          {:reply, error, %{state | history: history}}

        {:wait, history} ->
          {:noreply, %{state | history: history}}
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:adopt_history_request, server_id, pid, token, details}, {owner, _}, state) do
    with :ok <- history_runtime_current(state, server_id, pid),
         {:ok, %{pid: ^pid} = entry} <-
           HistoryLifecycle.owned_entry(state.history, server_id, token, owner),
         :ok <- matching_reservation(entry.lease[:details], details) do
      entry = %{entry | lease: Map.put(entry.lease, :details, details)}
      {:reply, :ok, %{state | history: Map.put(state.history, server_id, entry)}}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_history_lease}, state}
    end
  end

  def handle_call({:bind_history_request, server_id, token, details}, {owner, _}, state) do
    case HistoryLifecycle.owned_entry(state.history, server_id, token, owner) do
      {:ok, entry} ->
        case Map.get(entry.lease, :details) do
          nil ->
            entry = %{entry | lease: Map.put(entry.lease, :details, details)}
            {:reply, :ok, %{state | history: Map.put(state.history, server_id, entry)}}

          ^details ->
            {:reply, :ok, state}

          _ ->
            {:reply, {:error, :history_binding_conflict}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:history_requests, session}, {owner, _}, state) do
    requests =
      Enum.flat_map(state.history, fn
        {id, %{lease: %{owner: ^owner, details: %{session: ^session}} = lease}} ->
          [%{server_id: id, lease: lease}]

        _ ->
          []
      end)

    {:reply, requests, state}
  end

  def handle_call(
        {:history_projection, server_id, pid, token, binding, actor, projection},
        _from,
        state
      ) do
    case Map.get(state.history, server_id) do
      %{pid: ^pid, lease: %{token: ^token, details: %{history: %{binding: ^binding}}}} = entry ->
        update_history_projection(state, server_id, entry, actor, projection)

      _ ->
        {:reply, {:error, :stale_history_lease}, state}
    end
  end

  def handle_call({:pin_history_scope, transcript_id, actor, session}, {owner, _}, state) do
    with {:ok, principal} <- ExecutionActor.identity(actor),
         true <- is_reference(session) do
      history =
        HistoryLifecycle.pin_scope(state.history, transcript_id, principal, owner, session)

      {:reply, :ok, %{state | history: history}}
    else
      _ -> {:reply, {:error, :invalid_history_pin}, state}
    end
  end

  def handle_call({:release_history_pins, session}, {owner, _}, state) do
    state = %{state | history: HistoryLifecycle.release_pins(state.history, owner, session)}
    {:reply, :ok, check_retirements(state)}
  end

  def handle_call({:retire_history_scope, transcript_id, person_id}, _from, state) do
    history =
      Map.new(state.history, fn {id, entry} ->
        if entry.principal == {:person, person_id} and Map.has_key?(entry.cursors, transcript_id),
          do: {id, %{entry | retirement: entry.retirement || :requested}},
          else: {id, entry}
      end)

    {:reply, :ok, check_retirements(%{state | history: history})}
  end

  def handle_call({:admitted_history_target, pid, session}, {owner, _}, state) do
    result =
      Enum.reduce_while(state.history, :ok, fn
        {_id, %{pid: ^pid, retirement: reason, pins: pins}}, :ok when not is_nil(reason) ->
          if Map.has_key?(pins, {owner, session}),
            do: {:cont, :ok},
            else: {:halt, {:error, :server_retiring}}

        _, :ok ->
          {:cont, :ok}
      end)

    {:reply, result, state}
  end

  def handle_call({:abort_history_request, server_id, token}, {owner, _}, state) do
    case HistoryLifecycle.owned_entry(state.history, server_id, token, owner) do
      {:ok, entry} ->
        if safe_whereis(server_id) == entry.pid do
          _ = stop_server_if_running(server_id)
          {:reply, :ok, untrack_server(state, server_id)}
        else
          {:reply, :ok, %{state | history: HistoryLifecycle.drop(state.history, server_id)}}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:complete_history_request, server_id, token, context, cursors},
        {owner, _},
        state
      ) do
    case HistoryLifecycle.owned_entry(state.history, server_id, token, owner) do
      {:ok, entry} ->
        complete_history_lease(state, server_id, entry, token, context, cursors, owner)

      {:error, _} = error ->
        {:reply, error, state}
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

  def handle_call(
        {:stop_server_if_current, %ConfiguredAgent{} = configured_agent, server_id, expected_pid},
        _from,
        state
      ) do
    tracked? = server_id in tracked_server_ids(state, configured_agent.id)

    next_state =
      if tracked? and safe_whereis(server_id) == expected_pid,
        do: begin_stop(state, server_id),
        else: state

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

  def handle_call({:credential_dependency, server_id}, _from, state) do
    dependency = state |> Map.get(:credential_dependencies, %{}) |> Map.get(server_id)
    {:reply, dependency, state}
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
          |> configure_drain_timeout(server_id, opts)
          |> monitor_server(server_id)
          |> schedule_authentication_expiry(server_id, credential_dependency)
          |> initialize_history_cursor(server_id, opts)

        {:ok, server_id, next_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def handle_info({:expire_server, server_id, pid}, state) do
    if safe_whereis(server_id) == pid do
      expire_idle_incarnation(state, server_id, pid, state.history[server_id])
    else
      {:noreply, state}
    end
  end

  def handle_info({:history_idle_result, server_id, pid, ref, result}, state) do
    cond do
      safe_whereis(server_id) != pid ->
        {:noreply, state}

      ref == :idle and is_nil(state.history[server_id]) ->
        if result == :ok,
          do: stop_idle_incarnation(pid),
          else: Process.send_after(self(), {:expire_server, server_id, pid}, 100)

        {:noreply, state}

      match?(%{pid: ^pid, retirement: ^ref}, state.history[server_id]) ->
        finish_retirement_check(state, server_id, pid, result)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:check_history_retirements, server_id, pid}, state) do
    if safe_whereis(server_id) == pid,
      do: {:noreply, check_retirements(state)},
      else: {:noreply, state}
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

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case HistoryLifecycle.owner_scope(Map.get(state, :history, %{}), ref) do
      nil ->
        handle_runtime_down(ref, pid, reason, %{
          state
          | history: HistoryLifecycle.drop_waiter(state.history, ref)
        })

      server_id ->
        _ = stop_server_if_running(server_id)
        {:noreply, untrack_server(state, server_id)}
    end
  end

  def handle_info({:expire_history_waiter, server_id, id}, state) do
    {:noreply,
     check_retirements(%{
       state
       | history: HistoryLifecycle.expire_waiter(state.history, server_id, id)
     })}
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

  defp handle_runtime_down(ref, pid, reason, state) do
    case Enum.find(state.monitors, fn {_sid, r} -> r == ref end) do
      nil ->
        {:noreply, check_retirements(state)}

      {server_id, _ref} ->
        owner = crashed_history_owner(state, server_id, pid, reason)
        OpaqueAliases.clear_scope(server_id)
        state = untrack_server(state, server_id)
        if owner, do: Process.exit(owner, {:agent_runtime_down, reason})
        {:noreply, state}
    end
  end

  defp crashed_history_owner(state, server_id, pid, reason) do
    case get_in(state, [:history, server_id]) do
      %{pid: ^pid, lease: %{pid: ^pid, owner: owner}} when is_pid(owner) ->
        if reason not in [:normal, :shutdown] and not match?({:shutdown, _}, reason) and
             not draining?(state, server_id),
           do: owner

      _ ->
        nil
    end
  end

  defp spawn_agent_server(%ConfiguredAgent{} = configured_agent, server_id, context, actor, opts) do
    with {:ok, model_spec} <- ProviderSpec.build(configured_agent),
         {:ok, runtime_config} <-
           Factory.runtime_config(
             configured_agent,
             opts |> Keyword.take([:node_router_module]) |> Keyword.put(:actor, actor)
           ),
         :ok <-
           spawn_server(server_id, configured_agent, %{
             model: model_spec,
             runtime_config: runtime_config,
             execution_actor: actor,
             execution_scope: Keyword.get(opts, :execution_scope, server_id),
             history_binding: Keyword.get(opts, :history_binding),
             tool_context:
               Map.merge(runtime_config.tool_context, %{
                 configured_agent_id: configured_agent.id,
                 opaque_alias_scope: server_id
               }),
             context:
               Factory.build_initial_context(
                 configured_agent,
                 server_id,
                 context,
                 Keyword.get(opts, :history_binding)
               )
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
        validate_binding(pid, initial_state.execution_actor, initial_state.history_binding)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_binding(nil, _actor, _history_binding), do: :ok

  defp validate_binding(pid, actor, history_binding) do
    with {:ok, %{raw_state: raw_state}} <- Jido.AgentServer.status(pid),
         {:ok, bound_identity} <- ExecutionActor.identity(Map.get(raw_state, :execution_actor)),
         {:ok, identity} <- ExecutionActor.identity(actor),
         true <- Map.get(raw_state, :history_binding) == history_binding do
      if identity == bound_identity, do: :ok, else: {:error, :execution_actor_mismatch}
    else
      false ->
        {:error, :history_binding_mismatch}

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

  defp validate_history_binding(nil), do: {:ok, nil}

  defp validate_history_binding(%{conversation_id: id}) when is_binary(id) and id != "",
    do: {:ok, %{conversation_id: id}}

  defp validate_history_binding(_binding), do: {:error, :invalid_history_binding}

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

  defp drain_timeout_ms(opts) do
    Zaq.Config.get(:zaq, :agent_server_drain_timeout_ms, 1_500, opts)
  end

  defp configure_drain_timeout(state, server_id, opts) do
    timeouts = Map.get(state, :drain_timeouts, %{})

    timeouts =
      case Keyword.get(opts, :config) do
        config when config in [nil, Zaq.Config] -> Map.delete(timeouts, server_id)
        _config -> Map.put(timeouts, server_id, drain_timeout_ms(opts))
      end

    if map_size(timeouts) == 0,
      do: Map.delete(state, :drain_timeouts),
      else: Map.put(state, :drain_timeouts, timeouts)
  end

  defp runtime_drain_timeout_ms(state, server_id) do
    state
    |> Map.get(:drain_timeouts, %{})
    |> Map.get_lazy(server_id, fn -> drain_timeout_ms([]) end)
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

        _ =
          Process.send_after(
            self(),
            {:force_stop_server, server_id, ref},
            runtime_drain_timeout_ms(state, server_id)
          )

        %{state | draining: Map.put(state.draining, server_id, ref)}

      in_flight_requests?(server_id) ->
        ref = make_ref()

        _ =
          Process.send_after(
            self(),
            {:force_stop_server, server_id, ref},
            runtime_drain_timeout_ms(state, server_id)
          )

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
  catch
    # An unresponsive native incarnation is not proof that it is idle. Keep the
    # existing bounded drain instead of crashing the lifecycle/inspection owner.
    :exit, _ -> true
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
    state =
      Map.put(state, :history, HistoryLifecycle.drop(Map.get(state, :history, %{}), server_id))

    state = demonitor_server(state, server_id)
    agent_id = Map.get(state.server_to_agent, server_id)

    state =
      %{
        state
        | fingerprints: Map.delete(state.fingerprints, server_id),
          server_to_agent: Map.delete(state.server_to_agent, server_id),
          runtime_bindings: Map.delete(state.runtime_bindings, server_id),
          draining: Map.delete(state.draining, server_id)
      }
      |> delete_credential_dependency(server_id)
      |> configure_drain_timeout(server_id, [])

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

  defp initialize_history_cursor(state, server_id, opts) do
    {:ok, principal} = ExecutionActor.identity(Keyword.get(opts, :actor))

    state = %{
      state
      | runtime_bindings:
          Map.put(state.runtime_bindings, server_id, %{
            pid: safe_whereis(server_id),
            principal: principal,
            scope: Keyword.get(opts, :execution_scope, server_id),
            canonical_execution: Keyword.get(opts, :canonical_execution, false)
          })
    }

    Map.put(
      state,
      :history,
      HistoryLifecycle.initialize(
        Map.get(state, :history, %{}),
        server_id,
        safe_whereis(server_id),
        Keyword.get(opts, :history_cursors),
        principal
      )
    )
  end

  defp validate_history_actor(pid, actor) do
    with {:ok, actor} <- ExecutionActor.validate(actor),
         {:ok, identity} <- ExecutionActor.identity(actor),
         {:ok, %{raw_state: %{execution_actor: bound}}} <- Jido.AgentServer.status(pid),
         {:ok, ^identity} <- ExecutionActor.identity(bound) do
      :ok
    else
      _ -> {:error, :execution_actor_mismatch}
    end
  catch
    :exit, _ -> {:error, :stale_runtime}
  end

  defp update_history_projection(state, server_id, entry, actor, projection) do
    details = entry.lease.details

    with {:ok, identity} <- ExecutionActor.identity(actor),
         {:ok, ^identity} <- ExecutionActor.identity(details.actor),
         :ok <- HistoryLifecycle.validate_projection(details.history, projection) do
      if is_nil(projection) do
        {:reply, {:ok, details.history.projection}, state}
      else
        history = Map.put(details.history, :projection, projection)
        lease = %{entry.lease | details: %{details | history: history}}

        {:reply, {:ok, projection},
         %{state | history: Map.put(state.history, server_id, %{entry | lease: lease})}}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :unauthorized}, state}
    end
  end

  defp complete_history_lease(state, server_id, entry, token, context, cursors, owner) do
    case history_runtime_current(state, server_id, entry.pid) do
      :ok ->
        case HistoryLifecycle.complete(state.history, server_id, token, context, cursors, owner) do
          {:ok, history} ->
            {:reply, :ok, check_retirements(%{state | history: history})}

          {:error, reason} ->
            {:reply, {:error, reason}, state}

          {:invalidate, reason} ->
            _ = stop_server_if_running(server_id)
            {:reply, {:error, reason}, untrack_server(state, server_id)}
        end

      {:error, reason} ->
        {:reply, {:error, reason},
         %{state | history: HistoryLifecycle.drop(state.history, server_id)}}
    end
  end

  defp expire_idle_incarnation(state, server_id, pid, nil) do
    request_idle_check(server_id, pid, :idle)
    {:noreply, state}
  end

  defp expire_idle_incarnation(state, server_id, pid, entry) do
    if HistoryLifecycle.accepted_work?(entry) do
      Process.send_after(self(), {:expire_server, server_id, pid}, 100)
      {:noreply, state}
    else
      history =
        Map.put(state.history, server_id, %{entry | retirement: entry.retirement || :requested})

      {:noreply, check_retirements(%{state | history: history})}
    end
  end

  defp retiring_for_caller?(state, server_id, owner, session) do
    case state.history[server_id] do
      %{pid: pid, retirement: reason, pins: pins} when not is_nil(reason) ->
        safe_whereis(server_id) == pid and not Map.has_key?(pins, {owner, session})

      _ ->
        false
    end
  end

  defp check_retirements(state) do
    history =
      Map.new(state.history, fn {server_id, entry} ->
        if entry.retirement == :requested and not HistoryLifecycle.accepted_work?(entry) do
          ref = make_ref()
          request_idle_check(server_id, entry.pid, ref)
          {server_id, %{entry | retirement: ref}}
        else
          {server_id, entry}
        end
      end)

    %{state | history: history}
  end

  defp request_idle_check(server_id, pid, ref) do
    manager = self()

    Task.start(fn ->
      result = Factory.history_runtime_idle(pid)
      send(manager, {:history_idle_result, server_id, pid, ref, result})
    end)
  end

  defp finish_retirement_check(state, server_id, pid, result) do
    entry = state.history[server_id]

    if result == :ok and not HistoryLifecycle.accepted_work?(entry) do
      stop_idle_incarnation(pid)
      history = Map.put(state.history, server_id, %{entry | retirement: :stopping})
      {:noreply, %{state | history: history}}
    else
      Process.send_after(self(), {:check_history_retirements, server_id, pid}, 100)
      history = Map.put(state.history, server_id, %{entry | retirement: :requested})
      {:noreply, %{state | history: history}}
    end
  end

  defp stop_idle_incarnation(pid) do
    Task.start(fn -> DynamicSupervisor.terminate_child(@dynamic_supervisor, pid) end)
  end

  defp history_runtime_current(state, server_id, pid) do
    cond do
      draining?(state, server_id) -> {:error, :server_draining}
      safe_whereis(server_id) == pid -> :ok
      true -> {:error, :stale_runtime}
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

  defp history_incarnation_id(history, pid) do
    case Enum.filter(history, fn {_id, entry} -> entry.pid == pid end) do
      [{id, _}] -> {:ok, id}
      [] -> {:error, :stale_runtime}
      _ -> {:error, :ambiguous_request}
    end
  end

  defp matching_reservation(current, details) when is_map(current) do
    input_id = current[:input_id] || get_in(current, [:history, :binding, :user_message_id])

    if current[:session] == details[:session] and
         input_id == get_in(details, [:history, :binding, :user_message_id]) and
         ExecutionActor.identity(current[:actor]) == ExecutionActor.identity(details[:actor]),
       do: :ok,
       else: {:error, :history_binding_conflict}
  end

  defp matching_reservation(_, _), do: {:error, :history_binding_conflict}

  defp candidate_runtime?(_agent_id, _pid, nil), do: true
  defp candidate_runtime?(_agent_id, pid, expected) when is_pid(expected), do: pid == expected

  defp candidate_runtime?(id, _pid, %{agent_id: expected}),
    do: to_string(id) == to_string(expected)

  defp candidate_runtime?(_agent_id, _pid, _runtime), do: false

  defp snapshot_candidate(
         {id, %{pid: pid, principal: principal, scope: bound_scope}},
         state,
         principal,
         scope,
         runtime
       ) do
    agent_id = state.server_to_agent[id]

    if (is_nil(scope) or scope == bound_scope) and candidate_runtime?(agent_id, pid, runtime) and
         is_pid(pid) and safe_whereis(id) == pid do
      [
        candidate_binding(id, agent_id, pid, scope, state.history[id])
        |> Map.put(:canonical_execution, state.runtime_bindings[id].canonical_execution)
      ]
    else
      []
    end
  end

  defp snapshot_candidate(_entry, _state, _principal, _scope, _runtime), do: []

  defp candidate_binding(id, agent_id, pid, scope, history) do
    lease = matching_lease(history, pid)
    binding = get_in(lease, [:details, :history, :binding])

    %{
      server_id: id,
      runtime_pid: pid,
      agent: %{id: agent_id},
      requested_scope: scope,
      lease_token: get_in(lease, [:token]),
      lease_request_id: get_in(lease, [:request_id]),
      consumer_pid: get_in(lease, [:owner]),
      execution_user_message_id: get_in(binding, [:user_message_id]),
      execution_id: get_in(binding, [:execution_id])
    }
  end

  defp matching_lease(%{pid: pid, lease: lease}, pid), do: lease
  defp matching_lease(_history, _pid), do: nil

  defp current_target_lease?(_entry, %{lease_token: nil}), do: true

  defp current_target_lease?(%{pid: pid, lease: %{token: token, request_id: id}}, target),
    do: pid == target.runtime_pid and token == target.lease_token and id == target.request_id

  defp current_target_lease?(_entry, _target), do: false
end
