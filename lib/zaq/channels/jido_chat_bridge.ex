defmodule Zaq.Channels.JidoChatBridge do
  @moduledoc """
  Bridge for the jido_chat family of adapters (Mattermost, Telegram, etc.).

  `from_listener/3` is the `sink_mfa` target for adapter listeners. It forwards
  raw payloads to the per-bridge state process, where normalization and
  Jido.Chat event handling happen atomically.

  `send_reply/2` is called by Channels API for outbound delivery to any
  jido_chat-backed platform.

  `register_handlers/3` is called to attach function handlers per events

  All external module calls are configurable via Application env for testability.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.CommunicationBridge
  use Zaq.Channels.Bridge
  use Zaq.Channels.CommunicationBridge

  require Logger

  alias Jido.Chat
  alias Jido.Chat.Adapter
  alias Jido.Chat.Capabilities
  alias Jido.Chat.Thread

  alias Zaq.Channels.{
    AgentRouting,
    Bridge,
    ChannelConfig,
    RetrievalChannel,
    Supervisor
  }

  alias Zaq.Channels.JidoChatBridge.ListenerStatus
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  import Zaq.Engine.Messages, only: [is_present_message_id: 1]
  alias Zaq.{NodeRouter, System}
  alias Zaq.Types.EncryptedString

  @test_message "✅ **Zaq Connection Test**\nThis is an automated test message. If you see this, the channel is configured correctly."

  @doc """
  Sink target for `sink_mfa`. Always routes through the bridge state process.
  """
  def from_listener(config, payload, sink_opts) when is_map(payload) do
    bridge_id = sink_opts[:bridge_id] || runtime_bridge_id(config)

    with {:ok, normalized_config} <- ensure_provider_atom(config),
         :ok <- ensure_runtime_started(normalized_config, bridge_id, []),
         {:ok, state_pid} <- supervisor_module().lookup_state_pid(bridge_id) do
      state_module().process_listener_payload(state_pid, normalized_config, payload, sink_opts)
    end
  end

  @doc """
  Subscribes to replies for a specific thread. Starts a dedicated runtime bridge
  for `{channel_id, thread_id}`.
  """
  @impl true
  def subscribe_thread_reply(config, channel_id, thread_id)
      when is_binary(channel_id) and is_binary(thread_id) do
    bridge_id = thread_bridge_id(channel_id, thread_id)

    with {:ok, provider} <- provider_atom_from_config(config),
         :ok <- ensure_runtime_started(config, bridge_id, channel_ids: [channel_id]),
         {:ok, state_pid} <- supervisor_module().lookup_state_pid(bridge_id) do
      state_module().subscribe_thread(
        state_pid,
        provider,
        channel_id,
        thread_id
      )
    end
  end

  @doc """
  Unsubscribes from replies for a specific thread and stops the dedicated
  runtime bridge.
  """
  @impl true
  def unsubscribe_thread_reply(config, channel_id, thread_id)
      when is_binary(channel_id) and is_binary(thread_id) do
    bridge_id = thread_bridge_id(channel_id, thread_id)

    with {:ok, provider} <- provider_atom_from_config(config),
         {:ok, state_pid} <- supervisor_module().lookup_state_pid(bridge_id),
         :ok <-
           state_module().unsubscribe_thread(
             state_pid,
             provider,
             channel_id,
             thread_id
           ) do
      supervisor_module().stop_bridge_runtime(config, bridge_id)
    end
  end

  @impl true
  def build_runtime_specs(config) do
    bridge_id = runtime_bridge_id(config)

    with {:ok, state_spec} <- state_child_spec(config, bridge_id),
         {:ok, listeners} <- listener_specs(config, bridge_id, []) do
      {:ok, {state_spec, listeners}}
    end
  end

  @impl true
  def runtime_supervisor_module, do: supervisor_module()

  @impl true
  def start_runtime(config) do
    config = ChannelConfig.to_runtime_config(config)

    ensure_runtime_started(config, runtime_bridge_id(config), [])
  end

  @impl true
  def runtime_update_enabled_enabled(
        %{enabled: true} = before_config,
        %{enabled: true} = after_config
      ) do
    before_config = ChannelConfig.to_runtime_config(before_config)
    after_config = ChannelConfig.to_runtime_config(after_config)

    cond do
      runtime_restart_required?(before_config, after_config) ->
        restart_runtime(after_config)

      runtime_refresh_required?(before_config, after_config) ->
        refresh_runtime(after_config)

      true ->
        :ok
    end
  end

  @impl true
  def sync_provider_runtime(%{enabled: false} = config), do: stop_runtime(config)

  def sync_provider_runtime(%{enabled: true} = config),
    do: Bridge.restart_runtime(__MODULE__, ChannelConfig.to_runtime_config(config))

  @impl true
  def sync_runtime(before_config, after_config)

  def sync_runtime(nil, %{enabled: true} = after_config) do
    after_config = ChannelConfig.to_runtime_config(after_config)

    with :ok <- start_runtime(after_config) do
      ensure_ingress_on_enabled(after_config)
    end
  end

  def sync_runtime(%{enabled: false}, %{enabled: true} = after_config) do
    after_config = ChannelConfig.to_runtime_config(after_config)

    with :ok <- start_runtime(after_config) do
      ensure_ingress_on_enabled(after_config)
    end
  end

  def sync_runtime(%{enabled: true} = before_config, %{enabled: false} = after_config) do
    before_config = ChannelConfig.to_runtime_config(before_config)
    after_config = ChannelConfig.to_runtime_config(after_config)

    stop_result = stop_runtime(after_config)

    case teardown_ingress_on_disabled(before_config, after_config) do
      :ok -> stop_result
      {:error, reason} when stop_result == :ok -> {:error, {:ingress_teardown_failed, reason}}
      _ -> stop_result
    end
  end

  def sync_runtime(%{enabled: true} = before_config, %{enabled: true} = after_config) do
    before_config = ChannelConfig.to_runtime_config(before_config)
    after_config = ChannelConfig.to_runtime_config(after_config)

    cond do
      runtime_restart_required?(before_config, after_config) ->
        restart_runtime(after_config)

      runtime_refresh_required?(before_config, after_config) ->
        refresh_runtime(after_config)

      true ->
        :ok
    end
  end

  def sync_runtime(_before, _after), do: :ok

  @doc "Tests adapter connectivity by sending a test message."
  @impl true
  def test_connection(config, channel_id) do
    with {:ok, adapter} <- adapter_for(config.provider) do
      adapter.send_message(channel_id, @test_message, url: config.url, token: config.token)
    end
  end

  @impl true
  def channel_ingress_status(config) when is_map(config) do
    provider = Map.get(config, :provider) || Map.get(config, "provider")
    ingress_mode = ingress_mode_for(provider)

    case ingress_mode do
      mode when mode in [:websocket, :gateway, :polling] ->
        listener_runtime_status(config, mode)

      :webhook ->
        webhook_ingress_status(config)

      other ->
        {:ok,
         %{status: :unsupported, mode: to_string(other), summary: "Ingress mode is not supported"}}
    end
  end

  @impl true
  def ensure_ingress_subscription(config, params) when is_map(config) and is_map(params) do
    with :ok <- ensure_webhook_mode(config),
         {:ok, adapter} <- adapter_for(config.provider),
         true <-
           function_exported?(adapter, :ensure_ingress_subscription, 2) || {:error, :unsupported} do
      bridge_id = runtime_bridge_id(config)
      opts = ingress_subscription_opts(config, params)
      adapter.ensure_ingress_subscription(bridge_id, opts)
    end
  end

  @impl true
  def list_ingress_subscriptions(config, params) when is_map(config) and is_map(params) do
    with :ok <- ensure_webhook_mode(config),
         {:ok, adapter} <- adapter_for(config.provider),
         true <-
           function_exported?(adapter, :list_ingress_subscriptions, 2) || {:error, :unsupported} do
      bridge_id = runtime_bridge_id(config)
      opts = ingress_subscription_opts(config, params)
      adapter.list_ingress_subscriptions(bridge_id, opts)
    end
  end

  @impl true
  def delete_ingress_subscription(config, params) when is_map(config) and is_map(params) do
    with :ok <- ensure_webhook_mode(config),
         {:ok, adapter} <- adapter_for(config.provider),
         true <-
           function_exported?(adapter, :delete_ingress_subscription, 3) || {:error, :unsupported},
         {:ok, subscription_id} <- resolve_subscription_id(config, params),
         bridge_id <- runtime_bridge_id(config) do
      opts = ingress_subscription_opts(config, params)
      adapter.delete_ingress_subscription(bridge_id, subscription_id, opts)
    else
      {:error, :missing_subscription_id} ->
        {:ok, %{type: :ingress_webhook, deleted: false, reason: :missing_subscription_id}}

      other ->
        other
    end
  end

  @impl true
  def capability_snapshot(config) when is_map(config) do
    with {:ok, adapter} <- adapter_for(config.provider) do
      normalized_capabilities = Capabilities.channel_capabilities(adapter)
      adapter_capabilities = Adapter.capabilities(adapter)
      declared_capabilities = declared_adapter_capabilities(adapter)
      ingress_mode = ingress_mode_for(config.provider)

      resolved =
        Bridge.required_capabilities(:communication)
        |> Enum.reduce(%{}, fn capability, acc ->
          accumulate_capability(
            acc,
            capability,
            normalized_capabilities,
            adapter_capabilities,
            declared_capabilities,
            ingress_mode,
            adapter
          )
        end)

      {:ok, %{resolved: resolved}}
    end
  end

  @doc """
  Registers Jido.Chat handlers for a bridge runtime.
  """
  def register_handlers(%Chat{} = chat, config, _handler_opts \\ %{}) do
    message_patterns =
      ChannelConfig.jido_chat_setting(config, "message_patterns", [])
      |> Enum.filter(&is_binary/1)

    chat =
      chat
      |> Chat.on_new_mention(fn thread, incoming ->
        handle_mention_event(config, thread, incoming)
      end)
      |> Chat.on_subscribed_message(fn _thread, incoming ->
        handle_subscribed_message(incoming)
      end)
      |> Chat.on_new_message(~r/[\s\S]*/, fn thread, incoming ->
        if incoming.channel_meta.is_dm and not incoming.author.is_me do
          handle_message_event(config, thread, incoming)
        end
      end)

    Enum.reduce(message_patterns, chat, fn pattern, acc ->
      Chat.on_new_message(acc, pattern, fn thread, incoming ->
        handle_channel_message_event(config, thread, incoming)
      end)
    end)
  end

  defp handle_channel_message_event(config, thread, incoming) do
    unless incoming.channel_meta.is_dm do
      handle_message_event(config, thread, incoming)
    end
  end

  @doc "Processes a normalized incoming message from the listener pipeline."
  def handle_from_listener(config, %Chat.Incoming{} = incoming, _sink_opts) do
    if thread_reply?(incoming) do
      handle_subscribed_message(incoming)
    else
      thread = build_thread(incoming, config)
      handle_message_event(config, thread, incoming)
    end
  end

  @doc "Handles request-style webhook payloads through the jido_chat pipeline."
  @impl true
  def handle_webhook(config, payload) when is_map(config) and is_map(payload) do
    bridge_id = runtime_bridge_id(config)

    with :ok <- ensure_runtime_started(config, bridge_id, []),
         {:ok, state_pid} <- supervisor_module().lookup_state_pid(bridge_id),
         {:ok, ingress_result} <-
           state_module().process_webhook_request(state_pid, config, payload) do
      {:ok,
       %{
         provider: config.provider,
         handled: true,
         webhook_response: normalize_webhook_response_payload(ingress_result.response)
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_webhook_result, other}}
    end
  end

  @doc """
  Delivers `%Outgoing{}` to the Mattermost (or other jido_chat) platform.

  Called by Channels API after resolving connection details from the DB.
  Also dispatches `:on_reply` Oban jobs when `outgoing.metadata` carries such
  instructions (used by the notification center for reply tracking).
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  @impl true
  def send_reply(%Outgoing{} = outgoing, %{url: url, token: token}) do
    do_send_reply(outgoing, %{url: url, token: token})
  end

  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    Logger.warning(
      "[JidoChatBridge] send_reply called without connection details for channel=#{outgoing.channel_id}"
    )

    {:error, :missing_connection_details}
  end

  @impl true
  def upsert_message(%{provider: provider, provider_atom: provider_atom}, request, %{
        url: url,
        token: token
      })
      when is_map(request) do
    message_id = Map.get(request, :message_id)

    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- is_atom(provider_atom) || {:error, {:unsupported_provider, provider}},
         true <- supports_message_updates?(adapter) || {:ok, %{action: :noop, message_id: nil}} do
      thread_id = Map.get(request, :thread_id)
      channel_id = Map.get(request, :channel_id)
      body = Map.get(request, :body)
      request_metadata = Map.get(request, :metadata, request)

      if is_present_message_id(message_id) do
        edit_message(
          adapter,
          channel_id,
          message_id,
          body,
          url,
          token,
          Map.put(request, :metadata, request_metadata)
        )
      else
        create_message(
          provider_atom,
          adapter,
          channel_id,
          thread_id,
          body,
          url,
          token,
          request_metadata
        )
      end
    end
  end

  def upsert_message(
        %{provider: _provider, provider_atom: _provider_atom},
        _request,
        _connection_details
      ),
      do: {:error, :missing_connection_details}

  def upsert_message(%{provider: _provider}, _request, _connection_details),
    do: {:error, :missing_provider_atom}

  def upsert_message(_config, _request, _connection_details),
    do: {:error, :missing_connection_details}

  @doc "Fetches a user's canonical profile from the platform API."
  @spec fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def fetch_profile(author_id, %{url: url, token: token, provider: provider})
      when is_binary(author_id) do
    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- function_exported?(adapter, :get_user, 2) || {:error, :unsupported},
         {:ok, user} <- adapter.get_user(author_id, url: url, token: token) do
      {:ok,
       %{
         "email" => Map.get(user, :email) || Map.get(user, "email"),
         "display_name" =>
           Map.get(user, :display_name) || Map.get(user, "display_name") ||
             Map.get(user, :full_name) || Map.get(user, "full_name"),
         "username" => Map.get(user, :username) || Map.get(user, "username"),
         "phone" => Map.get(user, :phone) || Map.get(user, "phone")
       }}
    end
  end

  def fetch_profile(_author_id, _connection_details), do: {:error, :missing_connection_details}

  @spec send_typing(map() | String.t() | atom(), String.t() | integer(), map()) ::
          :ok | {:error, term()}
  @impl true
  def send_typing(%{provider: provider}, channel_id, details),
    do: send_typing(provider, channel_id, details)

  def send_typing(provider, channel_id, %{url: url, token: token}) do
    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- function_exported?(adapter, :start_typing, 2) || {:error, :unsupported},
         result <- adapter.start_typing(channel_id, url: url, token: token) do
      normalize_outbound_result(result)
    end
  end

  def send_typing(_provider, _channel_id, _connection_details),
    do: {:error, :missing_connection_details}

  @spec add_reaction(
          map() | String.t() | atom(),
          String.t() | integer(),
          String.t(),
          String.t(),
          map()
        ) ::
          :ok | {:error, term()}

  @impl true
  def add_reaction(%{provider: provider}, channel_id, message_id, emoji, details),
    do: add_reaction(provider, channel_id, message_id, emoji, details)

  def add_reaction(provider, channel_id, message_id, emoji, %{url: url, token: token})
      when is_present_message_id(message_id) and is_binary(emoji) do
    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- function_exported?(adapter, :add_reaction, 4) || {:error, :unsupported},
         result <- adapter.add_reaction(channel_id, message_id, emoji, url: url, token: token) do
      normalize_outbound_result(result)
    end
  end

  def add_reaction(_provider, _channel_id, _message_id, _emoji, _connection_details),
    do: {:error, :missing_connection_details}

  @spec remove_reaction(
          map() | String.t() | atom(),
          String.t() | integer(),
          String.t(),
          String.t(),
          map()
        ) ::
          :ok | {:error, term()}

  @impl true
  def remove_reaction(%{provider: provider}, channel_id, message_id, emoji, details),
    do: remove_reaction(provider, channel_id, message_id, emoji, details)

  def remove_reaction(
        provider,
        channel_id,
        message_id,
        emoji,
        %{url: url, token: token} = details
      )
      when is_present_message_id(message_id) and is_binary(emoji) do
    opts =
      [url: url, token: token]
      |> maybe_put_user_id(details)

    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- function_exported?(adapter, :remove_reaction, 4) || {:error, :unsupported},
         result <- adapter.remove_reaction(channel_id, message_id, emoji, opts) do
      normalize_outbound_result(result)
    end
  end

  def remove_reaction(_provider, _channel_id, _message_id, _emoji, _connection_details),
    do: {:error, :missing_connection_details}

  @doc "Converts a `Jido.Chat.Incoming` struct to the internal `Incoming` message format."
  @impl true
  def to_internal(%Chat.Incoming{} = incoming, provider) do
    Incoming.new(%{
      content: incoming.text,
      channel_id: incoming.external_room_id,
      thread_id: incoming.external_thread_id,
      message_id: incoming.external_message_id,
      author_id: incoming.author && incoming.author.user_id,
      author_name: incoming.author && incoming.author.user_name,
      provider: provider,
      channel_config_id: provider,
      is_dm: (incoming.channel_meta && Map.get(incoming.channel_meta, :is_dm)) == true,
      metadata: incoming.metadata || %{}
    })
  end

  @doc """
  Opens or returns the existing DM channel between the bot and a user.

  Requires `bot_user_id`, `url`, `token`, and `provider` in `connection_details`.
  Returns `{:ok, dm_channel_id}` on success.
  """
  @spec open_dm_channel(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  @impl true
  def open_dm_channel(author_id, %{url: url, token: token, bot_user_id: bot_user_id} = details)
      when is_binary(author_id) and is_binary(bot_user_id) do
    provider = Map.get(details, :provider, "mattermost")

    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- function_exported?(adapter, :open_dm_channel, 3) || {:error, :unsupported},
         {:ok, channel} <- adapter.open_dm_channel(bot_user_id, author_id, url: url, token: token),
         channel_id when is_binary(channel_id) <- channel["id"] || {:error, :missing_channel_id} do
      {:ok, channel_id}
    end
  end

  def open_dm_channel(_author_id, _details), do: {:error, :missing_connection_details}

  @doc "Resolves ZAQ roles for a message author by username. Returns `{:ok, roles | nil}`."
  def resolve_roles(%{author_name: nil}), do: {:ok, nil}

  def resolve_roles(%{author_name: author_name}) do
    accounts = accounts_module()
    permissions = permissions_module()

    role_ids =
      case accounts.get_user_by_username(author_name) do
        nil -> nil
        user -> permissions.list_accessible_role_ids(user)
      end

    {:ok, role_ids}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp handle_mention_event(config, thread, incoming) do
    if thread_reply?(incoming) do
      :ok
    else
      handle_message_event(config, thread, incoming)
    end
  end

  defp handle_subscribed_message(%Chat.Incoming{} = incoming) do
    post = %{
      root_id: incoming.external_thread_id,
      user_id: incoming.author && incoming.author.user_id,
      message: incoming.text
    }

    hooks_module().dispatch_sync(:reply_received, post, %{})
    :ok
  end

  defp handle_message_event(_config, _thread, %Chat.Incoming{author: %{is_me: true}}), do: :ok

  defp handle_message_event(config, thread, %Chat.Incoming{} = incoming) do
    msg = to_internal(incoming, thread.adapter_name)

    with {:ok, role_ids} <- resolve_roles(msg),
         :ok <-
           normalize_pipeline_result(
             route_incoming_message(
               msg,
               [role_ids: role_ids],
               agent_candidates(config, msg.channel_id),
               actor_from_incoming(msg),
               channel_config_id: Map.get(config, :id) || Map.get(config, "id"),
               pipeline_module: pipeline_module(),
               node_router: node_router_module()
             )
           ) do
      :telemetry.execute([:zaq, :chat_bridge, :message, :processed], %{count: 1}, %{
        provider: msg.provider
      })

      :ok
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

  defp build_thread(%Chat.Incoming{} = incoming, config) do
    thread_id = incoming.external_thread_id || incoming.external_room_id

    adapter_name =
      case incoming.channel_meta do
        %{adapter_name: name} when not is_nil(name) -> name
        _ -> Map.get(config, :provider, :mattermost)
      end

    adapter =
      adapter_name
      |> adapter_for()
      |> case do
        {:ok, mod} -> mod
        _ -> nil
      end

    Thread.new(%{
      id: "#{incoming.external_room_id}:#{thread_id}",
      adapter_name: adapter_name,
      adapter: adapter,
      external_room_id: incoming.external_room_id,
      external_thread_id: incoming.external_thread_id,
      metadata: %{url: config.url, token: config.token}
    })
  end

  @doc "Returns `{:ok, adapter_module}` for a provider atom/string, or `{:error, :unsupported_provider}`."
  def adapter_for(provider) do
    provider_key = if is_atom(provider), do: provider, else: provider_to_atom(provider)

    case provider_key do
      nil ->
        {:error, :unsupported_provider}

      key ->
        case Application.get_env(:zaq, :channels, %{}) |> get_in([key, :adapter]) do
          nil -> {:error, :unsupported_provider}
          adapter -> {:ok, adapter}
        end
    end
  end

  defp handler_opts(_config), do: %{}

  @doc "Builds the `{state_spec, listener_specs}` tuple for starting a bridge runtime."
  def runtime_specs(config, bridge_id, runtime_opts \\ []) do
    state_spec =
      case state_child_spec(config, bridge_id) do
        {:ok, spec} -> spec
        {:error, _reason} -> nil
      end

    listeners =
      case listener_specs(config, bridge_id, runtime_opts) do
        {:ok, specs} -> specs
        {:error, _} -> []
      end

    {state_spec, listeners}
  end

  defp thread_bridge_id(channel_id, thread_id), do: "#{channel_id}_#{thread_id}"

  defp ensure_runtime_started(config, bridge_id, runtime_opts) do
    case supervisor_module().lookup_state_pid(bridge_id) do
      {:ok, state_pid} ->
        case state_module().refresh_config(state_pid, config) do
          :ok -> :ok
          {:error, _reason} -> restart_runtime_for_bridge_id(config, bridge_id, runtime_opts)
        end

      {:error, :not_running} ->
        start_runtime_for_bridge_id(config, bridge_id, runtime_opts)
    end
  end

  defp start_runtime_for_bridge_id(config, bridge_id, runtime_opts) do
    with {:ok, state_spec} <- state_child_spec(config, bridge_id),
         {:ok, listeners} <- listener_specs(config, bridge_id, runtime_opts),
         {:ok, _runtime} <-
           supervisor_module().start_runtime(
             bridge_id,
             state_spec,
             listeners
           ) do
      :ok
    else
      {:error, :already_running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restart_runtime_for_bridge_id(config, bridge_id, runtime_opts) do
    case supervisor_module().stop_bridge_runtime(config, bridge_id) do
      :ok -> start_runtime_for_bridge_id(config, bridge_id, runtime_opts)
      {:error, :not_running} -> start_runtime_for_bridge_id(config, bridge_id, runtime_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_runtime(config) do
    case supervisor_module().lookup_state_pid(runtime_bridge_id(config)) do
      {:ok, state_pid} -> state_module().refresh_config(state_pid, config)
      {:error, :not_running} -> start_runtime(config)
    end
  end

  defp state_module do
    Application.get_env(:zaq, __MODULE__, [])
    |> Keyword.get(:state_module, State)
  end

  defp restart_runtime(config) do
    Bridge.restart_runtime(__MODULE__, config)
  end

  defp state_child_spec(config, bridge_id) do
    with {:ok, provider} <- provider_atom_from_config(config) do
      {:ok,
       %{
         id: {State, bridge_id},
         start:
           {State, :start_link,
            [
              [
                bridge_id: bridge_id,
                config: config,
                provider: provider,
                handler_opts: handler_opts(config)
              ]
            ]},
         restart: :permanent,
         type: :worker
       }}
    end
  end

  defp listener_specs(config, bridge_id, runtime_opts) do
    with {:ok, adapter} <- adapter_for(config.provider),
         true <- ingress_starts_listener?(ingress_mode_for(config.provider)),
         {:ok, specs} <-
           adapter.listener_child_specs(bridge_id, listener_opts(config, bridge_id, runtime_opts)) do
      {:ok, Enum.map(specs, &Map.put(&1, :restart, :temporary))}
    else
      false -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp listener_opts(config, bridge_id, runtime_opts) do
    channel_ids =
      Keyword.get_lazy(runtime_opts, :channel_ids, fn -> load_active_channel_ids(config) end)

    ingress_mode = ingress_mode_for(config.provider)

    default_ingress = %{"mode" => Atom.to_string(ingress_mode)}
    configured_ingress = ChannelConfig.jido_chat_setting(config, "ingress", %{})

    ingress =
      if is_map(configured_ingress),
        do: Map.merge(default_ingress, configured_ingress),
        else: default_ingress

    [
      url: config.url,
      token: config.token,
      bot_user_id: ChannelConfig.jido_chat_bot_user_id(config),
      bot_name: ChannelConfig.jido_chat_bot_name(config),
      channel_ids: channel_ids,
      bridge_id: bridge_id,
      ingress: ingress,
      sink_mfa: sink_mfa_for(config),
      sink_opts: [transport: ingress_mode, bridge_id: bridge_id]
    ]
  end

  defp sink_mfa_for(config), do: {__MODULE__, :from_listener, [config]}

  defp ingress_mode_for(provider) do
    provider_key = provider_to_atom(provider)

    Application.get_env(:zaq, :channels, %{})
    |> get_in([provider_key, :ingress_mode])
    |> Kernel.||(:websocket)
  end

  defp ingress_starts_listener?(mode), do: mode in [:websocket, :gateway, :polling]

  defp listener_runtime_status(config, mode) do
    bridge_id = runtime_bridge_id(config)

    case supervisor_module().lookup_runtime(bridge_id) do
      {:ok, %{listener_pids: listener_pids, state_pid: state_pid}} ->
        alive_listener_count = Enum.count(listener_pids, &Process.alive?/1)
        state_alive = is_pid(state_pid) and Process.alive?(state_pid)
        recorded_status = listener_recorded_status(state_pid)
        auth_status = ListenerStatus.query_listener_pids(listener_pids)

        {:ok,
         listener_status_payload(recorded_status, auth_status, mode, %{
           bridge_id: bridge_id,
           state_pid: inspect(state_pid),
           state_alive: state_alive,
           listeners_total: length(listener_pids),
           listeners_alive: alive_listener_count
         })}

      {:error, :not_running} ->
        {:ok,
         %{
           status: :error,
           mode: Atom.to_string(mode),
           summary: "Ingress runtime is not running",
           reason: :not_running,
           details: %{bridge_id: bridge_id}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp listener_status_payload(%{status: status} = recorded_status, _auth_status, mode, details)
       when status in [:error, "error"] do
    recorded_status
    |> Map.put_new(:mode, Atom.to_string(mode))
    |> Map.update(:details, Map.take(details, [:bridge_id]), fn recorded_details ->
      recorded_details
      |> status_details_map()
      |> Map.put_new(:bridge_id, details.bridge_id)
    end)
  end

  defp listener_status_payload(
         %{"status" => status} = recorded_status,
         _auth_status,
         mode,
         details
       )
       when status in [:error, "error"] do
    recorded_status
    |> Map.put_new(:mode, Atom.to_string(mode))
    |> Map.update(:details, Map.take(details, [:bridge_id]), fn recorded_details ->
      recorded_details
      |> status_details_map()
      |> Map.put_new(:bridge_id, details.bridge_id)
    end)
  end

  defp listener_status_payload(_recorded_status, auth_status, mode, details)
       when is_map(auth_status) do
    auth_status
    |> Map.put_new(:mode, Atom.to_string(mode))
    |> Map.update(:details, Map.take(details, [:bridge_id]), fn recorded_details ->
      recorded_details
      |> status_details_map()
      |> Map.put_new(:bridge_id, details.bridge_id)
    end)
  end

  defp listener_status_payload(recorded_status, _auth_status, mode, details)
       when is_map(recorded_status) do
    recorded_status
    |> Map.put_new(:mode, Atom.to_string(mode))
    |> Map.update(:details, Map.take(details, [:bridge_id]), fn recorded_details ->
      recorded_details
      |> status_details_map()
      |> Map.put_new(:bridge_id, details.bridge_id)
    end)
  end

  defp listener_status_payload(
         _recorded_status,
         _auth_status,
         mode,
         %{state_alive: false, listeners_alive: 0} = details
       ) do
    %{
      status: :error,
      mode: Atom.to_string(mode),
      summary: "Ingress runtime exists but no process is alive",
      reason: :runtime_not_alive,
      details: Map.take(details, [:bridge_id])
    }
  end

  defp listener_status_payload(_recorded_status, _auth_status, mode, details) do
    %{
      status: :pending,
      mode: Atom.to_string(mode),
      summary: "Ingress listener is connecting and authenticating",
      details: details
    }
  end

  defp listener_recorded_status(state_pid) when is_pid(state_pid) do
    state_module().ingress_status(state_pid)
  catch
    :exit, _ -> nil
  end

  defp listener_recorded_status(_state_pid), do: nil

  defp status_details_map(details) when is_map(details), do: details
  defp status_details_map(details), do: %{details: details}

  defp webhook_ingress_status(config) do
    case list_ingress_subscriptions(config, %{}) do
      {:ok, subscriptions} when is_list(subscriptions) and subscriptions != [] ->
        {:ok,
         %{
           status: :ok,
           mode: "webhook",
           summary: "Webhook ingress subscription is configured",
           details: %{subscriptions: subscriptions, count: length(subscriptions)}
         }}

      {:ok, []} ->
        {:ok,
         %{
           status: :warning,
           mode: "webhook",
           summary: "Webhook ingress subscription is not configured",
           reason: :not_configured,
           details: %{subscriptions: [], count: 0}
         }}

      {:error, :unsupported} ->
        {:ok,
         %{
           status: :unsupported,
           mode: "webhook",
           summary: "Adapter does not support webhook ingress subscription listing"
         }}

      {:error, reason} ->
        {:ok,
         %{
           status: :error,
           mode: "webhook",
           summary: "Webhook ingress status check failed",
           reason: reason
         }}

      other ->
        {:ok,
         %{
           status: :error,
           mode: "webhook",
           summary: "Webhook ingress status returned unexpected payload",
           reason: {:unexpected_result, other}
         }}
    end
  end

  defp ingress_subscription_opts(config, params) do
    bridge_id = runtime_bridge_id(config)
    ingress = normalized_ingress(config)
    token = normalized_subscription_token(config)

    [
      url: config.url,
      token: token,
      bridge_id: bridge_id,
      bridge_config: %{credentials: %{token: token}},
      settings: %{"ingress" => ingress},
      ingress: ingress,
      target_url:
        Map.get(params, :target_url) || Map.get(params, "target_url") ||
          webhook_target_url(config)
    ]
  end

  defp normalized_subscription_token(config) do
    token = Map.get(config, :token) || Map.get(config, "token")
    EncryptedString.decrypt!(token) || token
  end

  defp webhook_target_url(config) do
    with base when is_binary(base) and base != "" <- System.get_global_base_url() do
      "#{String.trim_trailing(base, "/")}/channels/webhook/conversation/#{config.provider}"
    end
  end

  defp resolve_subscription_id(config, params) do
    explicit = Map.get(params, :subscription_id) || Map.get(params, "subscription_id")

    if is_binary(explicit) and explicit != "" do
      {:ok, explicit}
    else
      with {:ok, subscriptions} <- list_ingress_subscriptions(config, params),
           %{} = subscription <- List.first(subscriptions),
           id when is_binary(id) and id != "" <-
             Map.get(subscription, :subscription_id) || Map.get(subscription, "subscription_id") do
        {:ok, id}
      else
        _ -> {:error, :missing_subscription_id}
      end
    end
  end

  defp ensure_webhook_mode(config) do
    if ingress_mode_for(config.provider) == :webhook, do: :ok, else: {:error, :unsupported}
  end

  defp ensure_ingress_on_enabled(config) do
    if ingress_mode_for(config.provider) == :webhook do
      case ensure_ingress_subscription(config, %{}) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, {:ingress_ensure_failed, reason}}
      end
    else
      :ok
    end
  end

  defp teardown_ingress_on_disabled(before_config, after_config) do
    if ingress_mode_for(before_config.provider) == :webhook do
      case delete_ingress_subscription(after_config, %{}) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp accumulate_capability(
         acc,
         capability,
         normalized_capabilities,
         adapter_capabilities,
         declared_capabilities,
         ingress_mode,
         adapter
       ) do
    case capability_value(
           capability,
           normalized_capabilities,
           adapter_capabilities,
           declared_capabilities,
           ingress_mode,
           adapter
         ) do
      nil -> acc
      value -> Map.put(acc, capability, value)
    end
  end

  defp capability_value(
         :mode,
         _normalized_capabilities,
         _adapter_capabilities,
         _declared_capabilities,
         ingress_mode,
         _adapter
       ),
       do: ingress_mode |> Atom.to_string()

  defp capability_value(
         :edit_messages,
         _normalized_capabilities,
         adapter_capabilities,
         declared_capabilities,
         _ingress_mode,
         adapter
       ) do
    if function_exported?(adapter, :edit_message, 4) do
      true
    else
      # `edit_messages` is a ZAQ BO diagnostic capability, not part of
      # `Jido.Chat.Capabilities`; keep this local bridge drift explicit.
      raw_capability_value(:edit_messages, declared_capabilities) ||
        raw_capability_value(:edit_message, declared_capabilities) ||
        raw_capability_value(:edit_message, adapter_capabilities)
    end
  end

  defp capability_value(
         capability,
         normalized_capabilities,
         adapter_capabilities,
         _declared_capabilities,
         _ingress_mode,
         _adapter
       ) do
    if capability in normalized_capabilities do
      public_capability_value(capability, adapter_capabilities) || true
    end
  end

  defp public_capability_value(capability, adapter_capabilities) do
    capability
    |> public_capability_keys()
    |> Enum.map(&raw_capability_value(&1, adapter_capabilities))
    |> best_capability_value()
  end

  defp public_capability_keys(:file), do: [:file, :send_file, :post_message]
  defp public_capability_keys(:image), do: [:image, :send_file, :post_message]
  defp public_capability_keys(:audio), do: [:audio, :send_file, :post_message]
  defp public_capability_keys(:video), do: [:video, :send_file, :post_message]
  defp public_capability_keys(:streaming), do: [:streaming, :stream]
  defp public_capability_keys(:reactions), do: [:reactions, :add_reaction, :remove_reaction]
  defp public_capability_keys(:threads), do: [:threads, :open_thread, :list_threads]
  defp public_capability_keys(:typing), do: [:typing, :start_typing]
  defp public_capability_keys(capability), do: [capability]

  defp best_capability_value(values) do
    cond do
      :native in values -> :native
      :fallback in values -> :fallback
      true in values -> true
      true -> nil
    end
  end

  defp raw_capability_value(capability, raw_capabilities) when is_map(raw_capabilities) do
    raw_capabilities
    |> Map.get(capability, Map.get(raw_capabilities, to_string(capability)))
    |> normalize_raw_capability_value()
  end

  defp raw_capability_value(_capability, _raw_capabilities), do: nil

  defp normalize_raw_capability_value(value) when value in [true, :native, :fallback], do: value

  defp normalize_raw_capability_value(value)
       when value in [false, nil, :unsupported, "unsupported"],
       do: nil

  defp normalize_raw_capability_value(value), do: value

  defp declared_adapter_capabilities(adapter) do
    if function_exported?(adapter, :capabilities, 0) do
      adapter.capabilities()
    else
      Adapter.capabilities(adapter)
    end
  end

  defp load_active_channel_ids(config) do
    case RetrievalChannel.list_active_by_config(config.id) |> Enum.map(& &1.channel_id) do
      [] -> :all
      ids -> ids
    end
  end

  defp runtime_restart_required?(before_config, after_config) do
    startup_fingerprint(before_config) != startup_fingerprint(after_config) or
      listener_fingerprint(before_config) != listener_fingerprint(after_config)
  end

  defp runtime_refresh_required?(before_config, after_config) do
    refresh_fingerprint(before_config) != refresh_fingerprint(after_config)
  end

  defp startup_fingerprint(config) do
    %{
      provider: Map.get(config, :provider) || Map.get(config, "provider"),
      url: Map.get(config, :url) || Map.get(config, "url"),
      token: Map.get(config, :token) || Map.get(config, "token")
    }
  end

  defp listener_fingerprint(config) do
    %{
      bot_name: ChannelConfig.jido_chat_bot_name(config),
      bot_user_id: ChannelConfig.jido_chat_bot_user_id(config),
      ingress: normalized_ingress(config)
    }
  end

  defp refresh_fingerprint(config) do
    %{
      bot_name: ChannelConfig.jido_chat_bot_name(config),
      message_patterns: normalized_message_patterns(config),
      provider_default_agent_id: ChannelConfig.get_provider_default_agent_id(config)
    }
  end

  defp normalized_ingress(config) do
    case ChannelConfig.jido_chat_setting(config, "ingress", %{}) do
      ingress when is_map(ingress) -> ingress
      _ -> %{}
    end
  end

  defp normalized_message_patterns(config) do
    config
    |> ChannelConfig.jido_chat_setting("message_patterns", [])
    |> Enum.filter(&is_binary/1)
  end

  def provider_to_atom(provider) when is_atom(provider), do: provider

  def provider_to_atom(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> nil
  end

  def provider_atom_from_config(config) when is_map(config) do
    case Map.get(config, :provider_atom) do
      provider when is_atom(provider) and not is_nil(provider) ->
        {:ok, provider}

      _ ->
        provider = Map.get(config, :provider) || Map.get(config, "provider")

        case resolve_provider_atom(provider) do
          {:ok, provider_atom} -> {:ok, provider_atom}
          :error -> {:error, :missing_provider_atom}
        end
    end
  end

  defp ensure_provider_atom(config) when is_map(config) do
    case provider_atom_from_config(config) do
      {:ok, provider_atom} -> {:ok, Map.put(config, :provider_atom, provider_atom)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_provider_atom(provider) when is_atom(provider), do: {:ok, provider}

  defp resolve_provider_atom(provider) when is_binary(provider) do
    channels = Application.get_env(:zaq, :channels, %{})

    Enum.find(Map.keys(channels), fn key -> Atom.to_string(key) == provider end)
    |> case do
      nil -> :error
      key -> {:ok, key}
    end
  end

  defp resolve_provider_atom(_provider), do: :error

  defp normalize_pipeline_result(result)

  defp normalize_pipeline_result(:ok), do: :ok
  defp normalize_pipeline_result(nil), do: :ok
  defp normalize_pipeline_result(%Outgoing{}), do: :ok
  defp normalize_pipeline_result({:ok, _}), do: :ok
  defp normalize_pipeline_result({:error, _} = error), do: error

  defp normalize_pipeline_result(other), do: {:error, {:invalid_pipeline_response, other}}

  @impl true
  def resolve_agent_selection(config, %Incoming{} = _incoming, opts) do
    channel_id = Keyword.get(opts, :channel_id)

    config
    |> agent_candidates(channel_id)
    |> AgentRouting.first_active_selection()
  end

  defp agent_candidates(config, channel_id) do
    [
      {:channel_assignment, channel_assignment_agent_choice(config, channel_id)},
      {:provider_default, ChannelConfig.get_provider_agent_choice(config)},
      {:global_default, System.get_global_default_agent_id()}
    ]
  end

  defp channel_assignment_agent_choice(config, channel_id) when is_binary(channel_id) do
    case Map.get(config, :id) || Map.get(config, "id") do
      id when is_integer(id) ->
        case RetrievalChannel.get_by_config_and_channel(id, channel_id) do
          %RetrievalChannel{agent_routing_mode: "none"} -> AgentRouting.none_value()
          %RetrievalChannel{configured_agent_id: configured_agent_id} -> configured_agent_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp channel_assignment_agent_choice(_config, _channel_id), do: nil

  # person is resolved by CommunicationBridge before dispatching to the agent node.
  defp actor_from_incoming(%Incoming{} = incoming) do
    %{
      id: incoming.author_id,
      name: incoming.author_name,
      provider: incoming.provider
    }
  end

  defp hooks_module do
    Application.get_env(:zaq, :pipeline_hooks_module, Zaq.Hooks)
  end

  defp pipeline_module do
    Application.get_env(:zaq, :chat_bridge_pipeline_module, Zaq.Agent.Pipeline)
  end

  def runtime_chat_module do
    Application.get_env(:zaq, :chat_bridge_chat_module, Chat)
  end

  defp accounts_module do
    Application.get_env(:zaq, :chat_bridge_accounts_module, Zaq.Accounts)
  end

  defp permissions_module do
    Application.get_env(:zaq, :chat_bridge_permissions_module, Zaq.Accounts.Permissions)
  end

  defp node_router_module do
    Application.get_env(:zaq, :chat_bridge_node_router_module, NodeRouter)
  end

  defp supervisor_module do
    Application.get_env(:zaq, :chat_bridge_supervisor_module, Supervisor)
  end

  defp oban_module do
    Application.get_env(:zaq, :chat_bridge_oban_module, Oban)
  end

  defp resolve_adapter_for_provider(provider) do
    case adapter_for(provider) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _} -> {:error, {:unsupported_provider, provider}}
    end
  end

  defp normalize_outbound_result(:ok), do: :ok
  defp normalize_outbound_result({:ok, _}), do: :ok
  defp normalize_outbound_result({:error, _} = err), do: err
  defp normalize_outbound_result(other), do: {:error, {:unexpected_response, other}}

  defp maybe_put_user_id(opts, %{user_id: user_id}) when is_binary(user_id),
    do: Keyword.put(opts, :user_id, user_id)

  defp maybe_put_user_id(opts, _), do: opts

  @doc "Returns the string key used to index a thread in the bridge state."
  def thread_key(provider, channel_id, thread_id) do
    provider_name = if is_atom(provider), do: Atom.to_string(provider), else: provider
    "#{provider_name}:#{channel_id}:#{thread_id}"
  end

  @doc "Sends a reply outbound via the provider adapter. Called by the bridge state process."
  def do_send_reply(%Outgoing{} = outgoing, %{url: url, token: token}) do
    case adapter_for(outgoing.provider) do
      {:ok, adapter_module} ->
        handle_send_with_adapter(outgoing, adapter_module, url, token)

      {:error, _reason} ->
        {:error, {:unsupported_provider, outgoing.provider}}
    end
  end

  defp handle_send_with_adapter(%Outgoing{} = outgoing, adapter_module, url, token) do
    metadata = outgoing.metadata || %{}

    with {:use_update, message_id} <- send_mode(outgoing, adapter_module),
         {:ok, _result} <-
           edit_message(
             adapter_module,
             outgoing.channel_id,
             message_id,
             outgoing.body,
             url,
             token,
             %{request_id: metadata[:request_id], metadata: metadata}
           ) do
      :ok
    else
      :create -> create_and_dispatch_reply(outgoing, adapter_module, url, token)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_mode(%Outgoing{} = outgoing, adapter_module) do
    case metadata_message_id(outgoing.metadata) do
      message_id when is_present_message_id(message_id) ->
        if supports_message_updates?(adapter_module), do: {:use_update, message_id}, else: :create

      _ ->
        :create
    end
  end

  defp create_and_dispatch_reply(%Outgoing{} = outgoing, adapter_module, url, token) do
    metadata = outgoing.metadata || %{}

    with {:ok, %{message_id: post_id}} <-
           create_message(
             outgoing.provider,
             adapter_module,
             outgoing.channel_id,
             outgoing.thread_id,
             outgoing.body,
             url,
             token,
             metadata
           ) do
      dispatch_on_reply(outgoing.metadata, post_id)
      :ok
    end
  end

  defp thread_reply?(%Chat.Incoming{external_thread_id: id}) when is_binary(id) and id != "",
    do: true

  defp thread_reply?(_), do: false

  def webhook_request_from_payload(payload, provider) do
    parsed_query = payload |> payload_value(["query", :query]) |> normalize_query()

    %{
      adapter_name: provider,
      method: payload_value(payload, ["method", :method], "POST"),
      path: payload_value(payload, ["path", :path]),
      headers: payload_value(payload, ["headers", :headers], %{}),
      payload: payload_value(payload, ["payload", :payload, "params", :params], %{}),
      query: parsed_query,
      raw: payload_value(payload, ["raw", :raw, "raw_body", :raw_body]),
      metadata: %{}
    }
  end

  defp normalize_query(query) when is_map(query), do: query

  defp normalize_query(query) when is_binary(query) and query != "",
    do: URI.decode_query(query)

  defp normalize_query(_query), do: %{}

  defp payload_value(payload, keys, default \\ nil) when is_map(payload) and is_list(keys) do
    Enum.find_value(keys, default, &Map.get(payload, &1))
  end

  def normalize_webhook_response_payload(%{status: status, headers: headers, body: body}) do
    %{
      status: status || 200,
      headers: headers || %{},
      body: body
    }
  end

  def normalize_webhook_response_payload(_), do: %{status: 200, headers: %{}, body: ""}

  # Dispatches an Oban on_reply job if the metadata requests it.
  # Used by the notification center for reply tracking.
  defp dispatch_on_reply(%{"on_reply" => %{"module" => mod_str, "args" => args}}, post_id) do
    module = String.to_existing_atom(mod_str)
    full_args = if post_id, do: Map.put(args, "post_id", post_id), else: args

    case module.new(full_args) |> oban_module().insert() do
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

  defp create_message(
         provider,
         adapter_module,
         channel_id,
         thread_id,
         body,
         url,
         token,
         metadata
       ) do
    effective_thread_id = thread_id || channel_id

    thread =
      Thread.new(%{
        id: "#{channel_id}:#{effective_thread_id}",
        adapter_name: provider,
        adapter: adapter_module,
        external_room_id: channel_id,
        external_thread_id: thread_id,
        metadata: %{url: url, token: token}
      })

    post_body = build_post_body(body, metadata)

    case Chat.Thread.post(thread, post_body, format_delivery_opts(url, token, metadata)) do
      {:ok, post} ->
        {:ok,
         %{
           action: :created,
           message_id: post.id
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp edit_message(adapter_module, channel_id, message_id, body, url, token, request) do
    metadata = Map.get(request, :metadata, %{})

    opts =
      [url: url, token: token, update_intent: Map.get(request, :update_intent)]
      |> maybe_put_format_from_metadata(metadata)

    result = adapter_module.edit_message(channel_id, message_id, body, opts)

    case normalize_outbound_result(result) do
      :ok -> {:ok, %{action: :updated, message_id: message_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp supports_message_updates?(adapter_module) do
    function_exported?(adapter_module, :edit_message, 4)
  end

  defp metadata_message_id(metadata) when is_map(metadata) do
    Map.get(metadata, :message_id) || Map.get(metadata, "message_id")
  end

  defp metadata_message_id(_), do: nil

  defp format_delivery_opts(url, token, metadata) do
    [url: url, token: token]
    |> maybe_put_format_from_metadata(metadata)
  end

  defp build_post_body(body, metadata) when is_binary(body) do
    %{text: body, formatted: body, metadata: post_metadata(metadata)}
  end

  defp build_post_body(body, _metadata), do: body

  defp post_metadata(metadata) when is_map(metadata) do
    case Map.get(metadata, :format) || Map.get(metadata, "format") do
      format when format in [:html, :plain_text, :markdown] -> %{format: format}
      _ -> %{}
    end
  end

  defp post_metadata(_metadata), do: %{}

  defp maybe_put_format_from_metadata(opts, metadata) when is_map(metadata) do
    case Map.get(metadata, :format) || Map.get(metadata, "format") do
      format when format in [:html, :plain_text, :markdown] -> Keyword.put(opts, :format, format)
      _ -> opts
    end
  end

  defp maybe_put_format_from_metadata(opts, _metadata), do: opts
end
