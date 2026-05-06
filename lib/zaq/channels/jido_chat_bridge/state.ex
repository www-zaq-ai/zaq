defmodule Zaq.Channels.JidoChatBridge.State do
  @moduledoc """
  Runtime state holder for one `JidoChatBridge` instance (`bridge_id`).

  This process owns the authoritative `%Jido.Chat{}` struct for the bridge and
  applies all incoming mutations sequentially through the GenServer message queue.

  Why this process exists:

  - `Jido.Chat` is stateful (subscriptions, dedupe, thread/channel state).
  - Multiple ingress sources can hit the same bridge concurrently.
  - A read/modify/write flow outside a single owner process risks races and
    divergent chat state.

  By funneling operations through this process, ZAQ keeps exactly one evolving
  `Jido.Chat` version per `bridge_id`, with deterministic ordering.

  Responsibilities:

  - Transform listener payloads and process them through `Jido.Chat`.
  - Keep subscriptions and runtime chat state in sync.
  - Refresh config while preserving runtime state that must survive reloads.
  - Delegate outbound bridge actions while keeping runtime ownership local.
  """

  use GenServer

  alias Jido.Chat
  alias Jido.Chat.Adapter
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.JidoChatBridge

  @type state :: %{
          bridge_id: String.t(),
          config: map(),
          chat: Chat.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # based on the `sink_opts` we might be using GenServer.call
  # Refering back to slack implementation: https://github.com/agentjido/jido_chat_slack/blob/f072de707c08540a08398436db5d7c668e778514/lib/jido/chat/slack/socket_mode_worker.ex#L162
  def process_listener_payload(pid, config, payload, sink_opts) do
    GenServer.cast(pid, {:process_listener_payload, config, payload, sink_opts})
  end

  def subscribe_thread(pid, provider, channel_id, thread_id) do
    GenServer.call(pid, {:subscribe_thread, provider, channel_id, thread_id})
  end

  def unsubscribe_thread(pid, provider, channel_id, thread_id) do
    GenServer.call(pid, {:unsubscribe_thread, provider, channel_id, thread_id})
  end

  def send_reply(pid, outgoing, connection_details) do
    GenServer.call(pid, {:send_reply, outgoing, connection_details}, :infinity)
  end

  def refresh_config(pid, config) do
    GenServer.call(pid, {:refresh_config, config})
  end

  def send_typing(pid, provider, channel_id, connection_details) do
    GenServer.call(pid, {:send_typing, provider, channel_id, connection_details}, :infinity)
  end

  def add_reaction(pid, provider, channel_id, message_id, emoji, connection_details) do
    GenServer.call(
      pid,
      {:add_reaction, provider, channel_id, message_id, emoji, connection_details},
      :infinity
    )
  end

  def remove_reaction(pid, provider, channel_id, message_id, emoji, connection_details) do
    GenServer.call(
      pid,
      {:remove_reaction, provider, channel_id, message_id, emoji, connection_details},
      :infinity
    )
  end

  @impl GenServer
  def init(opts) do
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    config = Keyword.fetch!(opts, :config)
    provider = Keyword.fetch!(opts, :provider)
    handler_opts = Keyword.get(opts, :handler_opts, %{})

    {:ok,
     %{bridge_id: bridge_id, config: config, chat: build_chat(config, provider, handler_opts)}}
  end

  @impl GenServer
  def handle_cast({:process_listener_payload, config, payload, sink_opts}, state) do
    {:ok, adapter} = JidoChatBridge.adapter_for(config.provider)
    transport = sink_opts[:transport] || :websocket

    result =
      with {:ok, incoming} <- Adapter.transform_incoming(adapter, payload),
           incoming <- with_transport(incoming, transport),
           thread_id <-
             JidoChatBridge.thread_key(
               incoming.channel_meta.adapter_name,
               incoming.external_room_id,
               incoming.external_thread_id || incoming.external_room_id
             ),
           {:ok, updated_chat, _} <-
             Chat.process_message(
               state.chat,
               incoming.channel_meta.adapter_name,
               thread_id,
               incoming,
               []
             ) do
        {:ok, updated_chat}
      end

    case result do
      {:ok, updated_chat} ->
        {:noreply, %{state | config: config, chat: updated_chat}}

      {:error, _reason} ->
        {:noreply, %{state | config: config}}
    end
  end

  @impl GenServer
  def handle_call({:subscribe_thread, provider, channel_id, thread_id}, _from, state) do
    key = JidoChatBridge.thread_key(provider, channel_id, thread_id)
    {:reply, :ok, %{state | chat: Chat.subscribe(state.chat, key)}}
  end

  def handle_call({:unsubscribe_thread, provider, channel_id, thread_id}, _from, state) do
    key = JidoChatBridge.thread_key(provider, channel_id, thread_id)
    {:reply, :ok, %{state | chat: Chat.unsubscribe(state.chat, key)}}
  end

  def handle_call({:send_reply, outgoing, connection_details}, _from, state) do
    {:reply, JidoChatBridge.do_send_reply(outgoing, connection_details), state}
  end

  def handle_call({:send_typing, provider, channel_id, connection_details}, _from, state) do
    {:reply, JidoChatBridge.send_typing(provider, channel_id, connection_details), state}
  end

  def handle_call(
        {:add_reaction, provider, channel_id, message_id, emoji, connection_details},
        _from,
        state
      ) do
    {:reply,
     JidoChatBridge.add_reaction(provider, channel_id, message_id, emoji, connection_details),
     state}
  end

  def handle_call(
        {:remove_reaction, provider, channel_id, message_id, emoji, connection_details},
        _from,
        state
      ) do
    {:reply,
     JidoChatBridge.remove_reaction(provider, channel_id, message_id, emoji, connection_details),
     state}
  end

  def handle_call({:refresh_config, config}, _from, state) do
    provider = String.to_existing_atom(config.provider)
    chat = build_chat(config, provider, %{})

    # Preserve runtime state while replacing handlers/adapters from latest config.
    chat = %{
      chat
      | subscriptions: state.chat.subscriptions,
        dedupe: state.chat.dedupe,
        dedupe_order: state.chat.dedupe_order,
        thread_state: state.chat.thread_state,
        channel_state: state.chat.channel_state
    }

    {:reply, :ok, %{state | config: config, chat: chat}}
  end

  defp with_transport(incoming, transport) do
    metadata = Map.put(incoming.metadata || %{}, :transport, transport)
    %{incoming | metadata: metadata}
  end

  defp build_chat(config, provider, handler_opts) do
    bot_name = ChannelConfig.jido_chat_bot_name(config) || "zaq"

    {:ok, adapter} = JidoChatBridge.adapter_for(config.provider)

    Chat.new(
      user_name: bot_name,
      adapters: %{provider => adapter}
    )
    |> JidoChatBridge.register_handlers(config, handler_opts)
  end
end
