defmodule Zaq.Channels.JidoChatBridge do
  @moduledoc """
  Bridge for the jido_chat family of adapters (Mattermost, Telegram, etc.).

  `from_listener/3` is the `sink_mfa` target for adapter listeners. It routes
  based on transport: `:webhook` payloads are enqueued via `IncomingChatWorker`
  for async Oban processing; all other transports (e.g. WebSocket) are
  transformed and handled inline.

  `send_reply/2` is called by the Router for outbound delivery to any
  jido_chat-backed platform.

  All external module calls are configurable via Application env for testability.
  """

  require Logger

  alias Jido.Chat
  alias Jido.Chat.Thread
  alias Zaq.Channels.{ChannelConfig, Router}
  alias Zaq.Channels.Workers.IncomingChatWorker
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.NodeRouter

  @doc """
  Sink target for `sink_mfa`. Routes based on transport:
  - `:webhook` — enqueues an Oban job via `IncomingChatWorker`
  - anything else — transforms and handles inline
  """
  def from_listener(config, payload, sink_opts) when is_map(payload) do
    if sink_opts[:transport] == :webhook do
      IncomingChatWorker.enqueue(config, payload, sink_opts)
    else
      adapter = ChannelConfig.resolve_adapter(config.provider)
      transport = sink_opts[:transport] || :websocket
      transform_and_handle(config, adapter, payload, transport)
    end
  end

  @doc """
  Transforms a raw adapter payload and dispatches it through the bridge.
  Called inline by `from_listener/3` and by `IncomingChatWorker` for the webhook path.
  """
  def transform_and_handle(config, adapter, payload, transport) do
    adapter_opts = [url: config.url, token: config.token]

    case adapter.transform_incoming(payload, adapter_opts) do
      {:ok, incoming} ->
        incoming = %{incoming | metadata: Map.put(incoming.metadata, :transport, transport)}
        handle_from_listener(config, incoming, [])

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Entry point for transformed ingress. Called directly for non-webhook
  transports, or by `IncomingChatWorker` after dequeuing a webhook job.
  """
  def handle_from_listener(config, %Chat.Incoming{} = incoming, _sink_opts) do
    thread = build_thread(incoming, config)
    handle_incoming(thread, incoming)
  end

  defp handle_incoming(thread, %Chat.Incoming{} = incoming) do
    Logger.info(
      "[JidoChatBridge] handle_incoming: external_thread_id=#{inspect(incoming.external_thread_id)} " <>
        "external_message_id=#{inspect(incoming.external_message_id)} " <>
        "thread_reply?=#{thread_reply?(incoming)}"
    )

    if thread_reply?(incoming) do
      Logger.info(
        "[JidoChatBridge] Thread reply received root_id=#{incoming.external_thread_id} user=#{incoming.author && incoming.author.user_id}"
      )

      post = %{
        root_id: incoming.external_thread_id,
        user_id: incoming.author && incoming.author.user_id,
        message: incoming.text
      }

      Logger.debug("[JidoChatBridge] Dispatching :reply_received post=#{inspect(post)}")
      Zaq.Hooks.dispatch_before(:reply_received, post, %{})
      :ok
    else
      msg = to_internal(incoming, thread.adapter_name)

      with {:ok, role_ids} <- resolve_roles(msg),
           outgoing <- NodeRouter.call(:agent, Zaq.Agent.Pipeline, :run, [msg, [role_ids: role_ids]]),
           :ok <- NodeRouter.call(:channels, Router, :deliver, [outgoing]) do
        :telemetry.execute([:zaq, :chat_bridge, :message, :processed], %{count: 1}, %{
          provider: msg.provider
        })

        NodeRouter.call(:engine, Zaq.Engine.Conversations, :persist_from_incoming, [msg, outgoing.metadata])
      else
        {:error, reason} ->
          :telemetry.execute([:zaq, :chat_bridge, :message, :failed], %{count: 1}, %{
            provider: msg.provider,
            reason: inspect(reason)
          })

          Logger.error(
            "[JidoChatBridge] Failed to process message " <>
              "channel=#{msg.channel_id} provider=#{msg.provider} reason=#{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Delivers `%Outgoing{}` to the Mattermost (or other jido_chat) platform.

  Called by `Zaq.Channels.Router` after resolving connection details from the DB.
  Also dispatches `:on_reply` Oban jobs when `outgoing.metadata` carries such
  instructions (used by the notification center for reply tracking).
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  def send_reply(%Outgoing{} = outgoing, %{url: url, token: token}) do
    case ChannelConfig.resolve_adapter(outgoing.provider) do
      nil ->
        {:error, {:unsupported_provider, outgoing.provider}}

      adapter_module ->
        thread_id = outgoing.thread_id || outgoing.channel_id

        thread =
          Thread.new(%{
            id: "#{outgoing.channel_id}:#{thread_id}",
            adapter_name: outgoing.provider,
            adapter: adapter_module,
            external_room_id: outgoing.channel_id,
            external_thread_id: outgoing.thread_id,
            metadata: %{url: url, token: token}
          })

        case Chat.Thread.post(thread, outgoing.body, url: url, token: token) do
          {:ok, post} ->
            post_id = post.response.external_message_id || post.id
            dispatch_on_reply(outgoing.metadata, post_id)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    Logger.warning(
      "[JidoChatBridge] send_reply called without connection details for channel=#{outgoing.channel_id}"
    )

    {:error, :missing_connection_details}
  end

  @doc false
  def to_internal(%Chat.Incoming{} = incoming, provider) do
    %Incoming{
      content: incoming.text,
      channel_id: incoming.external_room_id,
      thread_id: incoming.external_thread_id,
      message_id: incoming.external_message_id,
      author_id: incoming.author && incoming.author.user_id,
      author_name: incoming.author && incoming.author.user_name,
      provider: provider,
      metadata: incoming.metadata || %{}
    }
  end

  @doc false
  def resolve_roles(%{author_name: nil}), do: {:ok, nil}

  def resolve_roles(%{author_name: author_name}) do
    role_ids =
      case Zaq.Accounts.get_user_by_username(author_name) do
        nil -> nil
        user -> Zaq.Accounts.Permissions.list_accessible_role_ids(user)
      end

    {:ok, role_ids}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_thread(%Chat.Incoming{} = incoming, config) do
    thread_id = incoming.external_thread_id || incoming.external_room_id
    adapter_name = incoming.channel_meta.adapter_name
    adapter = resolve_adapter(adapter_name)

    Thread.new(%{
      id: "#{incoming.external_room_id}:#{thread_id}",
      adapter_name: adapter_name,
      adapter: adapter,
      external_room_id: incoming.external_room_id,
      external_thread_id: incoming.external_thread_id,
      metadata: %{url: config.url, token: config.token}
    })
  end

  defp resolve_adapter(adapter_name), do: ChannelConfig.resolve_adapter(adapter_name)

  defp thread_reply?(%Chat.Incoming{external_thread_id: id}) when is_binary(id) and id != "",
    do: true

  defp thread_reply?(_), do: false

  # Dispatches an Oban on_reply job if the metadata requests it.
  # Used by the notification center for reply tracking.
  defp dispatch_on_reply(%{"on_reply" => %{"module" => mod_str, "args" => args}}, post_id) do
    module = String.to_existing_atom(mod_str)
    full_args = if post_id, do: Map.put(args, "post_id", post_id), else: args

    case module.new(full_args) |> Oban.insert() do
      {:ok, job} ->
        Logger.info("[JidoChatBridge] on_reply job #{job.id} enqueued for #{inspect(mod_str)}")

      {:error, changeset} ->
        Logger.warning(
          "[JidoChatBridge] failed to enqueue on_reply for #{inspect(mod_str)}: #{inspect(changeset.errors)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "[JidoChatBridge] on_reply dispatch failed for #{inspect(mod_str)}: #{Exception.message(e)}"
      )
  end

  defp dispatch_on_reply(_metadata, _post_id), do: :ok

end
