defmodule Zaq.Channels.Supervisor do
  @moduledoc """
  Dynamic supervisor for channel bridge listener processes.

  On startup, loads all enabled retrieval channel configs from the database
  and starts the corresponding adapter listener processes. Supports runtime
  start/stop of listeners when channel configs are enabled or disabled.

  Each listener delivers incoming payloads to `JidoChatBridge.from_listener/3`
  via `sink_mfa`.

  `Zaq.NodeRouter` uses `Process.whereis/1` against this module to
  locate the channels node for cross-node RPC dispatch.
  """

  use DynamicSupervisor

  require Logger

  alias Zaq.Channels.{ChannelConfig, JidoChatBridge, RetrievalChannel}

  # ETS table: bridge_id => [pid]
  @table :zaq_channels_listeners

  def start_link(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    case DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} = result ->
        load_initial_listeners()
        result

      error ->
        error
    end
  end

  @impl DynamicSupervisor
  def init([]) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts listener processes for a channel config. No-ops if already running.
  Called via `NodeRouter.call(:channels, __MODULE__, :start_listener, [config])`.
  """
  def start_listener(config) do
    bridge_id = bridge_id(config)

    if running?(bridge_id) do
      Logger.info("[Channels.Supervisor] Listener already running for bridge_id=#{bridge_id}")
      {:error, :already_running}
    else
      do_start_listener(config, bridge_id)
    end
  end

  @doc """
  Stops listener processes for a channel config. No-ops if not running.
  Called via `NodeRouter.call(:channels, __MODULE__, :stop_listener, [config])`.
  """
  def stop_listener(config) do
    bridge_id = bridge_id(config)

    case :ets.lookup(@table, bridge_id) do
      [{^bridge_id, pids}] ->
        Enum.each(pids, &DynamicSupervisor.terminate_child(__MODULE__, &1))
        :ets.delete(@table, bridge_id)
        Logger.info("[Channels.Supervisor] Stopped listener for bridge_id=#{bridge_id}")
        :ok

      [] ->
        Logger.info("[Channels.Supervisor] No listener running for bridge_id=#{bridge_id}")
        {:error, :not_running}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_initial_listeners do
    providers = configured_providers()

    case ChannelConfig.list_enabled_by_kind(:retrieval, providers) do
      [] ->
        Logger.info("[Channels.Supervisor] No enabled channel configs found, starting empty.")

      configs ->
        Enum.each(configs, fn config ->
          do_start_listener(config, bridge_id(config))
        end)
    end
  end

  defp do_start_listener(config, bridge_id) do
    adapter = ChannelConfig.resolve_adapter(config.provider)

    if is_nil(adapter) do
      Logger.warning("[Channels.Supervisor] No adapter for provider=#{config.provider}, skipping config_id=#{config.id}")
      {:error, :no_adapter}
    else
      channel_ids = load_active_channel_ids(config)

      opts = [
        url: config.url,
        token: config.token,
        bot_user_id: config.bot_user_id,
        bot_name: config.bot_name,
        channel_ids: channel_ids,
        bridge_id: bridge_id,
        sink_mfa: {JidoChatBridge, :from_listener, [config]},
        sink_opts: [transport: ingress_mode(config.provider)]
      ]

      case adapter.listener_child_specs(bridge_id, opts) do
        {:ok, specs} ->
          pids =
            Enum.flat_map(specs, fn spec ->
              case DynamicSupervisor.start_child(__MODULE__, spec) do
                {:ok, pid} ->
                  [pid]

                {:error, reason} ->
                  Logger.warning("[Channels.Supervisor] Failed to start child for config_id=#{config.id}: #{inspect(reason)}")
                  []
              end
            end)

          :ets.insert(@table, {bridge_id, pids})
          {:ok, pids}

        {:error, reason} ->
          Logger.warning("[Channels.Supervisor] Could not build listener for config_id=#{config.id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.warning("[Channels.Supervisor] Exception starting listener for config_id=#{config.id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp running?(bridge_id) do
    case :ets.lookup(@table, bridge_id) do
      [{^bridge_id, pids}] -> Enum.any?(pids, &Process.alive?/1)
      [] -> false
    end
  end

  defp bridge_id(config), do: "#{config.provider}_#{config.id}"

  defp configured_providers do
    :zaq
    |> Application.get_env(:channels, %{})
    |> Enum.flat_map(fn {provider, cfg} ->
      if Map.has_key?(cfg, :adapter), do: [Atom.to_string(provider)], else: []
    end)
  end

  defp ingress_mode(provider) do
    :zaq
    |> Application.get_env(:channels, %{})
    |> get_in([String.to_existing_atom(provider), :ingress_mode])
    |> Kernel.||(:websocket)
  end

  defp load_active_channel_ids(config) do
    case RetrievalChannel.list_active_by_config(config.id) |> Enum.map(& &1.channel_id) do
      [] -> :all
      ids -> ids
    end
  end
end
