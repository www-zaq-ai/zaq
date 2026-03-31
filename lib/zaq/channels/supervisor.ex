defmodule Zaq.Channels.Supervisor do
  @moduledoc """
  Role marker for the `:channels` node role.
  `Zaq.NodeRouter` uses `Process.whereis/1` against this module to
  locate the channels node for cross-node RPC dispatch.

  Also starts WebSocket listeners for each enabled Mattermost config,
  so that thread replies from SMEs are delivered to the ChatBridge +
  PendingQuestions chain.
  """

  use Supervisor

  require Logger

  alias Zaq.Channels.{ChannelConfig, DiscordSupervisor, RetrievalChannel}
  alias Zaq.Channels.Workers.IncomingChatWorker

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_args) do
    {discord_children, other_children} = build_listener_children()
    nostrum_children = maybe_start_nostrum(discord_children)
    Supervisor.init(nostrum_children ++ other_children, strategy: :one_for_one)
  end

  defp maybe_start_nostrum([]) do
    Logger.debug("[Channels.Supervisor] No Discord listeners, skipping Nostrum")
    []
  end

  defp maybe_start_nostrum(discord_listener_children) do
    with {:config, %{token: token}} <- {:config, ChannelConfig.get_by_provider("discord")},
         {:token, true} <- {:token, is_binary(token) and token != ""} do
      Application.put_env(:nostrum, :token, token)

      Application.put_env(:nostrum, :gateway_intents, [
        :guild_messages,
        :message_content,
        :direct_messages
      ])

      {:ok, _} = Application.ensure_all_started(:gun)
      {:ok, _} = Application.ensure_all_started(:castle)

      Logger.info(
        "[Channels.Supervisor] Discord config found, starting Nostrum via DiscordSupervisor"
      )

      [DiscordSupervisor.child_spec(discord_listener_children)]
    else
      {:config, nil} ->
        Logger.warning(
          "[Channels.Supervisor] Discord listeners exist but no enabled config found, skipping Nostrum"
        )

        []

      {:token, false} ->
        Logger.warning(
          "[Channels.Supervisor] Discord config found but token is missing, skipping Nostrum"
        )

        []
    end
  rescue
    e ->
      Logger.warning(
        "[Channels.Supervisor] Failed to check Discord config: #{Exception.message(e)}"
      )

      []
  end

  defp channel_adapters do
    :zaq
    |> Application.get_env(:channels, %{})
    |> Enum.flat_map(fn {provider, cfg} ->
      case Map.fetch(cfg, :adapter) do
        {:ok, adapter} -> [{Atom.to_string(provider), adapter}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  # Returns {discord_listener_children, other_listener_children}.
  # Discord children are handled separately so DiscordSupervisor can sequence
  # Nostrum startup around them.
  defp build_listener_children do
    adapters = channel_adapters()
    providers = Map.keys(adapters)
    configs = ChannelConfig.list_enabled_by_kind(:retrieval, providers)

    {discord_configs, other_configs} = Enum.split_with(configs, &(&1.provider == "discord"))

    discord_children = Enum.flat_map(discord_configs, &listener_children_for_config(&1, adapters))
    other_children = Enum.flat_map(other_configs, &listener_children_for_config(&1, adapters))

    {discord_children, other_children}
  rescue
    e ->
      Logger.warning(
        "[Channels.Supervisor] Failed to load channel configs, starting with no listeners: #{Exception.message(e)}"
      )

      {[], []}
  end

  defp listener_children_for_config(%{provider: provider} = config, adapters) do
    case Map.fetch(adapters, provider) do
      {:ok, adapter} ->
        build_adapter_children(adapter, config)

      :error ->
        Logger.warning(
          "[Channels.Supervisor] No adapter registered for provider=#{provider}, skipping config_id=#{config.id}"
        )

        []
    end
  end

  defp build_adapter_children(adapter, config) do
    bridge_id = "#{config.provider}_#{config.id}"
    channel_ids = load_active_channel_ids(config)
    ingress_mode = get_ingress_mode(config.provider)

    opts = [
      url: config.url,
      token: config.token,
      bot_user_id: config.bot_user_id,
      bot_name: config.bot_name,
      channel_ids: channel_ids,
      bridge_id: bridge_id,
      ingress: %{mode: ingress_mode},
      sink_mfa: {IncomingChatWorker, :enqueue, [config]}
    ]

    case adapter.listener_child_specs(bridge_id, opts) do
      {:ok, specs} ->
        specs

      {:error, reason} ->
        Logger.warning(
          "[Channels.Supervisor] Could not build listener for config_id=#{config.id}: #{inspect(reason)}"
        )

        []
    end
  rescue
    e ->
      Logger.warning(
        "[Channels.Supervisor] Exception building listener for config_id=#{config.id}: #{Exception.message(e)}"
      )

      []
  end

  defp get_ingress_mode(provider) do
    :zaq
    |> Application.get_env(:channels, %{})
    |> get_in([String.to_existing_atom(provider), :ingress_mode])
    |> Kernel.||("websocket")
  end

  defp load_active_channel_ids(config) do
    channel_ids =
      config.id
      |> RetrievalChannel.list_active_by_config()
      |> Enum.map(& &1.channel_id)

    case channel_ids do
      [] -> :all
      ids -> ids
    end
  end
end
