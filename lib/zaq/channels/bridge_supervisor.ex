defmodule Zaq.Channels.BridgeSupervisor do
  @moduledoc """
  Dynamic supervisor for channel bridge listener processes.

  On startup, loads all enabled retrieval and data source channel configs from
  the database and starts the corresponding runtime processes. Supports runtime
  start/stop of listeners when channel configs are enabled or disabled.

  Listener processes deliver incoming payloads to the bridge sink callback
  configured by the active bridge runtime.

  Runs under `Zaq.Channels.Supervisor`, which retains the public runtime API and
  NodeRouter role-discovery name. Bootstrap runs on every dynamic child restart.
  The parent owns `:zaq_channels_listeners` and the private current-child index
  because it calls this `start_link/1`; both survive this child's restart and
  are cleared before reloading configs. The public runtime table retains its
  original bridge-ID/map shape; the private index follows automatic restarts.
  """

  use DynamicSupervisor

  require Logger

  alias Zaq.Channels.{CommunicationBridge, DataSourceBridge}
  alias Zaq.Engine.ChannelConfig

  # ETS table: bridge_id => %{listener_pids: [pid], state_pid: pid | nil}
  @table :zaq_channels_listeners
  @children_table :zaq_channels_runtime_children

  def start_link(_opts) do
    Enum.each([@table, @children_table], fn table ->
      if :ets.whereis(table) == :undefined, do: :ets.new(table, [:named_table, :public, :set])
    end)

    case DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} = result ->
        :ets.delete_all_objects(@table)
        :ets.delete_all_objects(@children_table)
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
    case runtime_entry(bridge_id) do
      [{^bridge_id, runtime}] ->
        try do
          stop_listener_children(runtime.listener_pids, bridge_id)
          stop_tracked_child(bridge_id, :state, runtime.state_pid)
        after
          delete_runtime_entry(bridge_id)
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
    case runtime_entry(bridge_id) do
      [{^bridge_id, runtime}] ->
        if runtime_alive?(runtime) or runtime == %{listener_pids: [], state_pid: nil},
          do: {:ok, runtime},
          else: {:error, :not_running}

      [] ->
        {:error, :not_running}
    end
  end

  @doc "Returns the state pid for a bridge id."
  @spec lookup_state_pid(String.t()) :: {:ok, pid()} | {:error, :not_running}
  def lookup_state_pid(bridge_id) when is_binary(bridge_id) do
    with {:ok, runtime} <- lookup_runtime(bridge_id),
         true <- is_pid(runtime.state_pid) and Process.alive?(runtime.state_pid) do
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
          "[Channels.BridgeSupervisor] No enabled #{kind} channel configs found, starting empty."
        )

      configs ->
        Enum.each(configs, fn config ->
          _ = runtime_module.sync_config_runtime(nil, config)
        end)
    end
  end

  defp do_start_runtime(bridge_id, state_spec, listener_specs) do
    # Reject malformed listener specs before starting any runtime children.
    listener_specs =
      Enum.map(listener_specs, fn spec ->
        spec = Supervisor.child_spec(spec, [])
        unless Map.has_key?(spec, :start), do: throw({:invalid_child_spec, spec})
        spec
      end)

    case maybe_start_state_process(tracked_spec(state_spec, bridge_id, :state)) do
      {:ok, state_pid} ->
        case start_listener_children(listener_specs, bridge_id) do
          {:ok, listener_pids} ->
            runtime = %{listener_pids: listener_pids, state_pid: state_pid}
            maybe_monitor_listeners(state_spec, state_pid, listener_pids)
            :ets.insert(@table, {bridge_id, runtime})
            {:ok, runtime}

          {:error, reason} = error ->
            stop_tracked_child(bridge_id, :state, state_pid)
            delete_runtime_entry(bridge_id)

            Logger.warning(
              "[Channels.BridgeSupervisor] Could not start runtime for bridge_id=#{bridge_id}: #{inspect(reason)}"
            )

            error
        end

      {:error, reason} = error ->
        delete_runtime_entry(bridge_id)

        Logger.warning(
          "[Channels.BridgeSupervisor] Could not start state process for bridge_id=#{bridge_id}: #{inspect(reason)}"
        )

        error
    end
  rescue
    e ->
      Logger.warning(
        "[Channels.BridgeSupervisor] Exception starting runtime bridge_id=#{bridge_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  catch
    {:invalid_child_spec, _spec} = reason ->
      listener_child_start_error(bridge_id, reason)
      {:error, reason}
  end

  defp start_listener_children(specs, bridge_id) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, pids} ->
      case DynamicSupervisor.start_child(__MODULE__, tracked_spec(spec, bridge_id, index)) do
        {:ok, pid} ->
          {:cont, {:ok, [pid | pids]}}

        {:error, {:already_started, pid}} ->
          {:cont, {:ok, [pid | pids]}}

        {:error, reason} ->
          stop_listener_children(Enum.reverse(pids), bridge_id)
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
      "[Channels.BridgeSupervisor] Failed to start child for bridge_id=#{bridge_id}: #{inspect(reason)}"
    )
  end

  defp stop_listener_children(pids, bridge_id) do
    pids
    |> Enum.with_index()
    |> Enum.each(fn {pid, slot} ->
      stop_tracked_child(bridge_id, slot, pid)
    end)
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
    case runtime_entry(bridge_id) do
      [{^bridge_id, runtime}] -> runtime_alive?(runtime)
      [] -> false
    end
  end

  defp runtime_alive?(%{listener_pids: pids, state_pid: state_pid}) do
    (is_pid(state_pid) and Process.alive?(state_pid)) or Enum.any?(pids, &Process.alive?/1)
  end

  # The owning parent can stop between an ETS presence check and the operation.
  # Only missing-table errors at this boundary represent an absent runtime.
  defp runtime_entry(bridge_id) do
    case :ets.lookup(@table, bridge_id) do
      [{^bridge_id, runtime}] ->
        state_pid = current_child(bridge_id, :state, runtime.state_pid)

        listeners =
          runtime.listener_pids
          |> Enum.with_index()
          |> Enum.map(fn {pid, index} -> current_child(bridge_id, index, pid) end)

        [{bridge_id, %{state_pid: state_pid, listener_pids: listeners}}]

      [] ->
        []
    end
  rescue
    ArgumentError -> []
  end

  defp delete_runtime_entry(bridge_id) do
    :ets.delete(@table, bridge_id)
    :ets.match_delete(@children_table, {{:runtime_child, bridge_id, :_}, :_})
  rescue
    ArgumentError -> :ok
  end

  defp tracked_spec(nil, _bridge_id, _slot), do: nil

  defp tracked_spec(spec, bridge_id, slot) do
    spec = Supervisor.child_spec(spec, [])
    %{spec | start: {__MODULE__, :start_tracked_child, [spec.start, bridge_id, slot]}}
  end

  @doc false
  def start_tracked_child({module, function, args}, bridge_id, slot) do
    result = apply(module, function, args)

    case result do
      {:ok, pid} ->
        :ets.insert(@children_table, {{:runtime_child, bridge_id, slot}, pid})

      {:ok, pid, _info} ->
        :ets.insert(@children_table, {{:runtime_child, bridge_id, slot}, pid})

      {:error, {:already_started, pid}} ->
        :ets.insert(@children_table, {{:runtime_child, bridge_id, slot}, pid})

      _ ->
        :ok
    end

    result
  end

  defp current_child(bridge_id, slot, fallback) do
    case :ets.lookup(@children_table, {:runtime_child, bridge_id, slot}) do
      [{_key, pid}] -> pid
      [] -> fallback
    end
  end

  defp stop_tracked_child(bridge_id, slot, fallback) do
    pid = current_child(bridge_id, slot, fallback)

    case safe_terminate_child(pid) do
      {:error, :not_found} ->
        replacement = current_child(bridge_id, slot, pid)
        if replacement != pid, do: stop_tracked_child(bridge_id, slot, replacement), else: :ok

      _ ->
        :ok
    end
  end

  defp bridge_id(config), do: "#{config.provider}_#{config.id}"

  # Runtime construction is supplied by the configured provider adapter.
  # ChannelConfig handles sub-provider matching (`email` matches `email:imap`).
  defp configured_providers do
    :zaq
    |> Application.get_env(:channels, %{})
    |> Enum.flat_map(fn {provider, cfg} ->
      if is_map(cfg) and Map.has_key?(cfg, :adapter),
        do: [to_string(provider)],
        else: []
    end)
  end
end
