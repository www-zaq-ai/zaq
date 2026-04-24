defmodule Zaq.Agent.ServerManager do
  @moduledoc """
  Starts and maintains one long-lived AgentServer per configured agent id or per-person scope.
  """

  use GenServer

  require Logger

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Factory

  @dynamic_supervisor Zaq.Agent.AgentServerSupervisor
  @jido_instance Zaq.Agent.Jido
  @jido_registry Jido.registry_name(@jido_instance)

  @type state :: %{
          fingerprints: %{optional(integer()) => binary()},
          last_active: %{optional(String.t()) => DateTime.t()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_server(ConfiguredAgent.t()) :: {:ok, GenServer.server()} | {:error, term()}
  def ensure_server(%ConfiguredAgent{} = configured_agent) do
    GenServer.call(__MODULE__, {:ensure_server, configured_agent})
  end

  @spec ensure_answering_server(String.t()) :: {:ok, GenServer.server()} | {:error, term()}
  def ensure_answering_server(server_id) when is_binary(server_id) do
    GenServer.call(__MODULE__, {:ensure_answering_server, server_id})
  end

  @spec ensure_server_by_id(ConfiguredAgent.t(), String.t()) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_server_by_id(%ConfiguredAgent{} = configured_agent, server_id)
      when is_binary(server_id) do
    GenServer.call(__MODULE__, {:ensure_server_by_id, configured_agent, server_id})
  end

  @spec last_active(String.t()) :: DateTime.t() | nil
  def last_active(server_id) when is_binary(server_id) do
    GenServer.call(__MODULE__, {:last_active, server_id})
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
    {:ok, %{fingerprints: %{}, last_active: %{}}}
  end

  @impl true
  def handle_call({:ensure_server, %ConfiguredAgent{} = configured_agent}, _from, state) do
    case do_ensure_server(configured_agent, state) do
      {:ok, server_id, next_state} -> {:reply, {:ok, server_ref(server_id)}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:ensure_answering_server, server_id}, _from, state) do
    state = put_in(state, [:last_active, server_id], DateTime.utc_now())

    result =
      case safe_whereis(server_id) do
        pid when is_pid(pid) ->
          {:ok, server_ref(server_id)}

        _ ->
          case DynamicSupervisor.start_child(
                 @dynamic_supervisor,
                 {Jido.AgentServer,
                  [
                    agent: Factory,
                    jido: @jido_instance,
                    registry: @jido_registry,
                    id: server_id,
                    initial_state: %{model: Factory.build_model_spec()}
                  ]}
               ) do
            {:ok, _pid} -> {:ok, server_ref(server_id)}
            {:error, {:already_started, _}} -> {:ok, server_ref(server_id)}
            {:error, reason} -> {:error, reason}
          end
      end

    {:reply, result, state}
  end

  def handle_call(
        {:ensure_server_by_id, %ConfiguredAgent{} = configured_agent, server_id},
        _from,
        state
      ) do
    state = put_in(state, [:last_active, server_id], DateTime.utc_now())
    fingerprint = fingerprint(configured_agent)

    result =
      case safe_whereis(server_id) do
        pid when is_pid(pid) ->
          {:ok, server_ref(server_id)}

        _ ->
          with {:ok, model_spec} <- model_spec(configured_agent),
               {:ok, runtime_config} <- Factory.runtime_config(configured_agent),
               {:ok, _pid} <-
                 DynamicSupervisor.start_child(
                   @dynamic_supervisor,
                   {Jido.AgentServer,
                    [
                      agent: Factory,
                      jido: @jido_instance,
                      registry: @jido_registry,
                      id: server_id,
                      initial_state: %{
                        model: model_spec,
                        runtime_config: runtime_config,
                        tool_context: %{configured_agent_id: configured_agent.id}
                      }
                    ]}
                 ) do
            {:ok, server_ref(server_id)}
          else
            {:error, {:already_started, _}} -> {:ok, server_ref(server_id)}
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

  def handle_call({:last_active, server_id}, _from, state) do
    {:reply, Map.get(state.last_active, server_id), state}
  end

  def handle_call({:stop_server, agent_id}, _from, state) do
    int_id = parse_int_id(agent_id)
    server_id = Agent.agent_server_id(int_id)

    _ = stop_server_if_running(server_id)

    {:reply, :ok, %{state | fingerprints: Map.delete(state.fingerprints, int_id)}}
  end

  def handle_call({:stop_server_by_raw_id, server_id}, _from, state) do
    _ = stop_server_if_running(server_id)

    {:reply, :ok, %{state | last_active: Map.delete(state.last_active, server_id)}}
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
    with {:ok, model_spec} <- model_spec(configured_agent),
         {:ok, runtime_config} <- Factory.runtime_config(configured_agent),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(
             @dynamic_supervisor,
             {Jido.AgentServer,
              [
                agent: Factory,
                jido: @jido_instance,
                registry: @jido_registry,
                id: server_id,
                initial_state: %{
                  model: model_spec,
                  runtime_config: runtime_config,
                  tool_context: %{configured_agent_id: configured_agent.id}
                }
              ]}
           ) do
      {:ok, server_id, put_in(state, [:fingerprints, configured_agent.id], fingerprint)}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp model_spec(%ConfiguredAgent{} = configured_agent) do
    case Agent.runtime_provider_for_agent(configured_agent) do
      {:ok, runtime_provider} ->
        credential =
          configured_agent.credential ||
            Zaq.System.get_ai_provider_credential(configured_agent.credential_id)

        if needs_inline_model_shape?(configured_agent, runtime_provider) do
          {:ok, %{provider: runtime_provider, id: configured_agent.model}}
        else
          provider_opts =
            []
            |> Keyword.put(:model, configured_agent.model)
            |> maybe_put(:base_url, credential && credential.endpoint)
            |> maybe_put(:api_key, credential && credential.api_key)

          {:ok, {runtime_provider, provider_opts}}
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp needs_inline_model_shape?(%ConfiguredAgent{} = configured_agent, runtime_provider) do
    Agent.provider_for_agent(configured_agent) != Atom.to_string(runtime_provider)
  end

  defp parse_int_id(id) when is_integer(id), do: id

  defp parse_int_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> raise ArgumentError, "invalid configured agent id: #{inspect(id)}"
    end
  end
end
