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

  def handle_call({:ensure_server_raw, server_id}, _from, state) do
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
          case spawn_agent_server(configured_agent, server_id) do
            :ok -> {:ok, server_ref(server_id)}
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
    case spawn_agent_server(configured_agent, server_id) do
      :ok -> {:ok, server_id, put_in(state, [:fingerprints, configured_agent.id], fingerprint)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp spawn_agent_server(%ConfiguredAgent{} = configured_agent, server_id) do
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
      :ok
    end
  end

  defp model_spec(%ConfiguredAgent{} = configured_agent) do
    credential =
      configured_agent.credential ||
        Zaq.System.get_ai_provider_credential(configured_agent.credential_id)

    with {:ok, runtime_provider} <- resolve_runtime_provider(configured_agent, credential) do
      spec = %{provider: runtime_provider, id: configured_agent.model}
      {:ok, maybe_put_model_base_url(spec, runtime_provider, credential)}
    end
  end

  # Falls back to :openai only when the provider is unknown to both ReqLLM and LLMDB
  # but the credential carries an explicit endpoint — the endpoint signals an intentional
  # custom OpenAI-compatible setup.
  defp resolve_runtime_provider(configured_agent, credential) do
    case Agent.runtime_provider_for_agent(configured_agent) do
      {:ok, _} = ok -> ok
      {:error, :provider_not_found} -> openai_if_custom_endpoint(credential)
      error -> error
    end
  end

  defp openai_if_custom_endpoint(%{endpoint: url}) when is_binary(url) and url != "",
    do: {:ok, :openai}

  defp openai_if_custom_endpoint(_), do: {:error, :provider_not_found}

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

  defp maybe_put_model_base_url(spec, provider, credential) do
    if Factory.fixed_url_provider?(provider) do
      spec
    else
      case credential do
        %{endpoint: url} when is_binary(url) and url != "" -> Map.put(spec, :base_url, url)
        _ -> spec
      end
    end
  end

  defp parse_int_id(id) when is_integer(id), do: id

  defp parse_int_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> raise ArgumentError, "invalid configured agent id: #{inspect(id)}"
    end
  end
end
