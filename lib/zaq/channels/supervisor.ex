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

  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Channels.Workers.IncomingChatWorker

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

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
