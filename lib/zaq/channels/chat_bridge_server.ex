defmodule Zaq.Channels.ChatBridgeServer do
  @moduledoc """
  GenServer that owns the `Jido.Chat` struct state and routes inbound events
  from the webhook controller through the Jido.Chat event pipeline.

  Mattermost ingress is webhook-only — no persistent workers are started.
  Inbound flow: Mattermost HTTP POST → Phoenix controller → `handle_event/3` →
  `Jido.Chat.process_event/4` → registered `ChatBridge` handlers.

  Adapters are loaded from the `channel_configs` table on startup and on
  `reconfigure/0`. Starts idle (empty adapters) when no enabled Mattermost
  config exists. Adapters can be injected via `start_link/1` opts for tests.
  """

  use GenServer

  alias Zaq.Channels.ChatBridge

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Routes a raw adapter event through the bridge. Called by the webhook controller."
  def handle_event(server \\ __MODULE__, adapter_name, raw_event) do
    GenServer.call(server, {:handle_event, adapter_name, raw_event})
  end

  @doc "Reloads adapter config from the database. Call after a channel config is saved/toggled."
  def reconfigure(server \\ __MODULE__) do
    GenServer.call(server, :reconfigure)
  end

  @impl true
  def init(opts) do
    adapters =
      case Keyword.fetch(opts, :adapters) do
        {:ok, a} -> a
        :error -> default_adapters()
      end

    chat = ChatBridge.build(adapters)
    {:ok, chat}
  end

  @impl true
  def handle_call({:handle_event, adapter_name, raw_event}, _from, chat) do
    result =
      try do
        Jido.Chat.process_event(chat, adapter_name, raw_event)
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      {:ok, updated_chat, _payload} -> {:reply, :ok, updated_chat}
      {:error, _reason} = error -> {:reply, error, chat}
    end
  end

  def handle_call(:reconfigure, _from, _chat) do
    chat = ChatBridge.build(default_adapters())
    {:reply, :ok, chat}
  end

  defp default_adapters do
    Zaq.Channels.ChannelConfig.list_enabled_by_kind(:retrieval)
    |> Enum.filter(&(&1.provider == "mattermost"))
    |> Enum.reduce(%{}, fn config, acc ->
      adapter = {Jido.Chat.Mattermost.Adapter, url: config.url, token: config.token}
      Map.put(acc, :"mattermost_#{config.id}", adapter)
    end)
  end
end
