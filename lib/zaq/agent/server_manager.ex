defmodule Zaq.Agent.ServerManager do
  @moduledoc """
  Starts and maintains one long-lived AgentServer per configured agent scope.

  The scope is determined upstream and passed in as a `server_id` string — it
  can represent any granularity (agent-wide, per-person, per-channel, etc.).
  Raw servers spawned via `ensure_server/1` (string form) are automatically
  stopped after an idle TTL using a scheduled message.
  """

  use GenServer

  require Logger

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Factory
  alias Zaq.Agent.ProviderSpec

  @dynamic_supervisor Zaq.Agent.AgentServerSupervisor
  @jido_instance Zaq.Agent.Jido
  @jido_registry Jido.registry_name(@jido_instance)

  @type state :: %{
          fingerprints: %{optional(integer()) => binary()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_server(ConfiguredAgent.t() | String.t()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_server(%ConfiguredAgent{} = configured_agent) do
    GenServer.call(__MODULE__, {:ensure_server, configured_agent})
  end

  def ensure_server(server_id) when is_binary(server_id) do
    GenServer.call(__MODULE__, {:ensure_server_raw, server_id})
  end

  @spec ensure_server_by_id(ConfiguredAgent.t(), String.t()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_server_by_id(%ConfiguredAgent{} = configured_agent, server_id)
      when is_binary(server_id) do
    GenServer.call(__MODULE__, {:ensure_server_by_id, configured_agent, server_id})
  end

  @spec stop_server(integer() | String.t()) :: :ok
  def stop_server(server_id) when is_binary(server_id) do
    case Integer.parse(server_id) do
      {int_id, ""} ->
        GenServer.call(__MODULE__, {:stop_server, int_id})

      _ ->
        GenServer.call(__MODULE__, {:stop_server_by_raw_id, server_id})
    end
  end

  def stop_server(agent_id) when is_integer(agent_id) do
    GenServer.call(__MODULE__, {:stop_server, agent_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{fingerprints: %{}}}
  end

  @impl true
  def handle_call({:ensure_server, %ConfiguredAgent{} = configured_agent}, _from, state) do
    case do_ensure_server(configured_agent, state) do
      {:ok, server_id, next_state} -> {:reply, {:ok, server_ref(server_id)}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:ensure_server_raw, server_id}, _from, state) do
    result =
      case safe_whereis(server_id) do
        pid when is_pid(pid) ->
          {:ok, server_ref(server_id)}

        _ ->
          case spawn_server(server_id, %{model: ProviderSpec.build()}) do
            :ok ->
              Process.send_after(self(), {:expire_server, server_id}, idle_ttl_ms())
              {:ok, server_ref(server_id)}

            {:error, reason} ->
              {:error, reason}
          end
      end

    {:reply, result, state}
  end

  def handle_call(
        {:ensure_server_by_id, %ConfiguredAgent{} = configured_agent, server_id},
        _from,
        state
      ) do
    fingerprint = fingerprint(configured_agent)

    result =
      case safe_whereis(server_id) do
        pid when is_pid(pid) ->
          {:ok, server_ref(server_id)}

        _ ->
          case spawn_agent_server(configured_agent, server_id) do
            :ok -> {:ok, server_ref(server_id)}
            {:error, reason} -> {:error, reason}
          end
      end

    next_state =
      case result do
        {:ok, _} -> put_in(state, [:fingerprints, configured_agent.id], fingerprint)
        _ -> state
      end

    {:reply, result, next_state}
  end

  def handle_call({:stop_server, agent_id}, _from, state) do
    int_id = parse_int_id(agent_id)
    server_id = Agent.agent_server_id(int_id)

    _ = stop_server_if_running(server_id)

    {:reply, :ok, %{state | fingerprints: Map.delete(state.fingerprints, int_id)}}
  end

  def handle_call({:stop_server_by_raw_id, server_id}, _from, state) do
    _ = stop_server_if_running(server_id)

    {:reply, :ok, state}
  end

  defp do_ensure_server(%ConfiguredAgent{} = configured_agent, state) do
    int_id = configured_agent.id
    server_id = Agent.agent_server_id(int_id)
    fingerprint = fingerprint(configured_agent)

    case {Map.get(state.fingerprints, int_id), safe_whereis(server_id)} do
      {^fingerprint, pid} when is_pid(pid) ->
        {:ok, server_id, state}

      {_previous, pid} when is_pid(pid) ->
        _ = stop_server_if_running(server_id)
        start_server(configured_agent, server_id, state, fingerprint)

      _ ->
        start_server(configured_agent, server_id, state, fingerprint)
    end
  end

  defp start_server(%ConfiguredAgent{} = configured_agent, server_id, state, fingerprint) do
    case spawn_agent_server(configured_agent, server_id) do
      :ok -> {:ok, server_id, put_in(state, [:fingerprints, configured_agent.id], fingerprint)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_info({:expire_server, server_id}, state) do
    _ = stop_server_if_running(server_id)
    {:noreply, state}
  end

  defp spawn_agent_server(%ConfiguredAgent{} = configured_agent, server_id) do
    with {:ok, model_spec} <- ProviderSpec.build(configured_agent),
         {:ok, runtime_config} <- Factory.runtime_config(configured_agent) do
      spawn_server(server_id, %{
        model: model_spec,
        runtime_config: runtime_config,
        tool_context: %{configured_agent_id: configured_agent.id}
      })
    end
  end

  defp spawn_server(server_id, initial_state) do
    case DynamicSupervisor.start_child(
           @dynamic_supervisor,
           {Jido.AgentServer,
            [
              agent: Factory,
              jido: @jido_instance,
              registry: @jido_registry,
              id: server_id,
              initial_state: initial_state
            ]}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp idle_ttl_ms do
    Application.get_env(:zaq, :agent_server_idle_ttl_ms, 30 * 60 * 1_000)
  end

  defp stop_server_if_running(server_id) do
    case safe_whereis(server_id) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
      _ -> :ok
    end
  end

  defp safe_whereis(server_id) do
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
      configured_agent.job,
      configured_agent.strategy,
      configured_agent.enabled_tool_keys,
      configured_agent.advanced_options,
      configured_agent.active,
      configured_agent.conversation_enabled
    })
    |> Integer.to_string()
  end

  defp parse_int_id(id) when is_integer(id), do: id

  defp parse_int_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> raise ArgumentError, "invalid configured agent id: #{inspect(id)}"
    end
  end
end
