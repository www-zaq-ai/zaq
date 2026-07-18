defmodule Zaq.Channels.Supervisor do
  @moduledoc """
  Dynamic supervisor for channel bridge listener processes.

  On startup, loads all enabled retrieval and data source channel configs from
  the database and starts the corresponding runtime processes. Supports runtime
  start/stop of listeners when channel configs are enabled or disabled.

  Listener processes deliver incoming payloads to the bridge sink callback
  configured by the active bridge runtime.

  `Zaq.NodeRouter` uses `Process.whereis/1` against this module to
  locate the channels node for cross-node RPC dispatch.
  """

  use DynamicSupervisor

  require Logger

  alias Zaq.Channels.{Bridge, ChannelConfig, CommunicationBridge, DataSourceBridge}

  # ETS table: bridge_id => %{listener_pids: [pid], state_pid: pid | nil}
  @table :zaq_channels_listeners

  def start_link(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    case DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} = result ->
        load_initial_runtimes()
        result

      error ->
        error
    end
  end

  @impl DynamicSupervisor
  def init([]) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts runtime for a config via router bridge delegation."
  def start_listener(config) do
    case CommunicationBridge.sync_config_runtime(
           %{enabled: false},
           Map.put(config, :enabled, true)
         ) do
      :ok -> lookup_runtime(bridge_id(config))
      error -> error
    end
  end

  @doc "Stops runtime for a config via router bridge delegation."
  def stop_listener(config) do
    CommunicationBridge.sync_config_runtime(
      Map.put(config, :enabled, true),
      Map.put(config, :enabled, false)
    )
  end

  @doc "Starts runtime processes for a bridge id."
  def start_runtime(bridge_id, state_spec, listener_specs \\ [])

  def start_runtime(bridge_id, state_spec, listener_specs)
      when is_binary(bridge_id) and (is_nil(state_spec) or is_map(state_spec)) and
             is_list(listener_specs) do
    if running?(bridge_id) do
      {:error, :already_running}
    else
      do_start_runtime(bridge_id, state_spec, listener_specs)
    end
  end

  @doc "Stops a bridge runtime by bridge id."
  def stop_bridge_runtime(_config, bridge_id) do
    case :ets.lookup(@table, bridge_id) do
      [{^bridge_id, runtime}] ->
        try do
          Enum.each(runtime.listener_pids, &safe_terminate_child/1)
          maybe_stop_state(runtime.state_pid)
        after
          :ets.delete(@table, bridge_id)
        end

        :ok

      [] ->
        {:error, :not_running}
    end
  end

  @doc "Returns runtime pids for a bridge id."
  @spec lookup_runtime(String.t()) ::
          {:ok, %{listener_pids: [pid()], state_pid: pid() | nil}} | {:error, :not_running}
  def lookup_runtime(bridge_id) when is_binary(bridge_id) do
    case :ets.lookup(@table, bridge_id) do
      [{^bridge_id, runtime}] -> {:ok, runtime}
      [] -> {:error, :not_running}
    end
  end

  @doc "Returns the state pid for a bridge id."
  @spec lookup_state_pid(String.t()) :: {:ok, pid()} | {:error, :not_running}
  def lookup_state_pid(bridge_id) when is_binary(bridge_id) do
    with {:ok, runtime} <- lookup_runtime(bridge_id),
         true <- is_pid(runtime.state_pid) do
      {:ok, runtime.state_pid}
    else
      _ -> {:error, :not_running}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_initial_runtimes do
    load_initial_runtimes_for(:retrieval, CommunicationBridge)
    load_initial_runtimes_for(:data_source, DataSourceBridge)
  end

  defp load_initial_runtimes_for(kind, runtime_module) do
    providers = configured_providers()

    case ChannelConfig.list_enabled_by_kind(kind, providers) do
      [] ->
        Logger.info(
          "[Channels.Supervisor] No enabled #{kind} channel configs found, starting empty."
        )

      configs ->
        Enum.each(configs, fn config ->
          _ = runtime_module.sync_config_runtime(nil, config)
        end)
    end
  end

  defp do_start_runtime(bridge_id, state_spec, listener_specs) do
    case maybe_start_state_process(state_spec) do
      {:ok, state_pid} ->
        case start_listener_children(listener_specs, bridge_id) do
          {:ok, listener_pids} ->
            runtime = %{listener_pids: listener_pids, state_pid: state_pid}
            maybe_monitor_listeners(state_spec, state_pid, listener_pids)
            :ets.insert(@table, {bridge_id, runtime})
            {:ok, runtime}

          {:error, reason} = error ->
            maybe_stop_state(state_pid)
            :ets.delete(@table, bridge_id)

            Logger.warning(
              "[Channels.Supervisor] Could not start runtime for bridge_id=#{bridge_id}: #{inspect(reason)}"
            )

            error
        end

      {:error, reason} = error ->
        Logger.warning(
          "[Channels.Supervisor] Could not start state process for bridge_id=#{bridge_id}: #{inspect(reason)}"
        )

        error
    end
  rescue
    e ->
      Logger.warning(
        "[Channels.Supervisor] Exception starting runtime bridge_id=#{bridge_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  defp start_listener_children(specs, bridge_id) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, pids} ->
      case DynamicSupervisor.start_child(__MODULE__, spec) do
        {:ok, pid} ->
          {:cont, {:ok, [pid | pids]}}

        {:error, {:already_started, pid}} ->
          {:cont, {:ok, [pid | pids]}}

        {:error, reason} ->
          Enum.each(pids, &DynamicSupervisor.terminate_child(__MODULE__, &1))
          listener_child_start_error(bridge_id, reason)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pids} -> {:ok, Enum.reverse(pids)}
      {:error, _} = error -> error
    end
  end

  defp listener_child_start_error(bridge_id, reason) do
    Logger.warning(
      "[Channels.Supervisor] Failed to start child for bridge_id=#{bridge_id}: #{inspect(reason)}"
    )
  end

  defp start_state_process(spec) do
    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_state_process(nil), do: {:ok, nil}
  defp maybe_start_state_process(spec), do: start_state_process(spec)

  defp maybe_stop_state(pid) when is_pid(pid), do: safe_terminate_child(pid)

  defp maybe_stop_state(_), do: :ok

  defp maybe_monitor_listeners(state_spec, state_pid, listener_pids) when is_pid(state_pid) do
    case state_module_from_spec(state_spec) do
      module when is_atom(module) ->
        if function_exported?(module, :monitor_listeners, 2),
          do: module.monitor_listeners(state_pid, listener_pids),
          else: :ok

      nil ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp maybe_monitor_listeners(_state_spec, _state_pid, _listener_pids), do: :ok

  defp state_module_from_spec(%{start: {module, :start_link, _args}}), do: module
  defp state_module_from_spec(_state_spec), do: nil

  defp safe_terminate_child(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_terminate_child(_), do: :ok

  defp running?(bridge_id) do
    case :ets.lookup(@table, bridge_id) do
      [{^bridge_id, %{listener_pids: pids, state_pid: state_pid}}] ->
        (is_pid(state_pid) and Process.alive?(state_pid)) or Enum.any?(pids, &Process.alive?/1)

      [] ->
        false
    end
  end

  defp bridge_id(config), do: "#{config.provider}_#{config.id}"

  # Expands each configured bridge key into every provider string that may be
  # stored under it. `config :zaq, :channels` is keyed by bridge (`:email`)
  # while rows use sub-providers (`"email:imap"`), so comparing the raw key
  # against `channel_configs.provider` skipped IMAP channels on every cold boot.
  defp configured_providers do
    :zaq
    |> Application.get_env(:channels, %{})
    |> Enum.flat_map(fn {provider, cfg} ->
      if Map.has_key?(cfg, :adapter), do: Bridge.bridge_key_to_providers(provider), else: []
    end)
  end
end
