defmodule Zaq.Channels.JidoChatBridge do
  @moduledoc """
  Bridge for the jido_chat family of adapters (Mattermost, Telegram, etc.).

  `from_listener/3` is the `sink_mfa` target for adapter listeners. It forwards
  raw payloads to the per-bridge state process, where normalization and
  Jido.Chat event handling happen atomically.

  `send_reply/2` is called by the Router for outbound delivery to any
  jido_chat-backed platform.

  All external module calls are configurable via Application env for testability.
  """

  @behaviour Zaq.Channels.Bridge

  require Logger

  alias Jido.Chat
  alias Jido.Chat.Thread
  alias Zaq.Channels.{Bridge, ChannelConfig, RetrievalChannel, Router, Supervisor}
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.{Event, NodeRouter, System}

  @test_message "✅ **Zaq Connection Test**\nThis is an automated test message. If you see this, the channel is configured correctly."

  @doc """
  Sink target for `sink_mfa`. Always routes through the bridge state process.
  """
  def from_listener(config, payload, sink_opts) when is_map(payload) do
    bridge_id = sink_opts[:bridge_id] || default_bridge_id(config)

    with :ok <- ensure_runtime_started(config, bridge_id, []),
         {:ok, state_pid} <- Supervisor.lookup_state_pid(bridge_id) do
      State.process_listener_payload(state_pid, config, payload, sink_opts)
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

    with :ok <- ensure_runtime_started(config, bridge_id, channel_ids: [channel_id]),
         {:ok, state_pid} <- Supervisor.lookup_state_pid(bridge_id) do
      State.subscribe_thread(
        state_pid,
        String.to_existing_atom(config.provider),
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

    with {:ok, state_pid} <- Supervisor.lookup_state_pid(bridge_id),
         :ok <-
           State.unsubscribe_thread(
             state_pid,
             String.to_existing_atom(config.provider),
             channel_id,
             thread_id
           ) do
      Supervisor.stop_bridge_runtime(config, bridge_id)
    end
  end

  @doc "Starts runtime processes for a channel config."
  @impl true
  def start_runtime(config) do
    bridge_id = default_bridge_id(config)

    ensure_runtime_started(config, bridge_id, [])
  end

  @doc "Stops runtime processes for a channel config."
  @impl true
  def stop_runtime(config) do
    case Supervisor.stop_bridge_runtime(config, default_bridge_id(config)) do
      :ok -> :ok
      {:error, :not_running} -> :ok
      other -> other
    end
  end

  @doc "Synchronizes runtime behavior for config changes owned by this bridge."
  def sync_runtime(nil, %{enabled: true} = config), do: start_runtime(config)
  def sync_runtime(nil, %{enabled: false}), do: :ok
  def sync_runtime(%{enabled: true}, %{enabled: false} = config), do: stop_runtime(config)
  def sync_runtime(%{enabled: false}, %{enabled: true} = config), do: start_runtime(config)

  def sync_runtime(%{enabled: true} = before_config, %{enabled: true} = after_config) do
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

  @doc "Synchronizes runtime from canonical provider config owned by this bridge."
  def sync_provider_runtime(%{enabled: false} = config), do: stop_runtime(config)
  def sync_provider_runtime(%{enabled: true} = config), do: restart_runtime(config)

  @doc "Tests adapter connectivity by sending a test message."
  @impl true
  def test_connection(config, channel_id) do
    with {:ok, adapter} <- adapter_for(config.provider) do
      adapter.send_message(channel_id, @test_message, url: config.url, token: config.token)
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

  @doc """
  Delivers `%Outgoing{}` to the Mattermost (or other jido_chat) platform.

  Called by `Zaq.Channels.Router` after resolving connection details from the DB.
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

  @spec send_typing(map() | String.t() | atom(), String.t(), map()) :: :ok | {:error, term()}
  @impl true
  def send_typing(%{provider: provider}, channel_id, details),
    do: send_typing(provider, channel_id, details)

  def send_typing(provider, channel_id, %{url: url, token: token}) when is_binary(channel_id) do
    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- function_exported?(adapter, :start_typing, 2) || {:error, :unsupported},
         result <- adapter.start_typing(channel_id, url: url, token: token) do
      normalize_outbound_result(result)
    end
  end

  def send_typing(_provider, _channel_id, _connection_details),
    do: {:error, :missing_connection_details}

  @spec add_reaction(map() | String.t() | atom(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}

  @impl true
  def add_reaction(%{provider: provider}, channel_id, message_id, emoji, details),
    do: add_reaction(provider, channel_id, message_id, emoji, details)

  def add_reaction(provider, channel_id, message_id, emoji, %{url: url, token: token})
      when is_binary(channel_id) and is_binary(message_id) and is_binary(emoji) do
    with {:ok, adapter} <- resolve_adapter_for_provider(provider),
         true <- function_exported?(adapter, :add_reaction, 4) || {:error, :unsupported},
         result <- adapter.add_reaction(channel_id, message_id, emoji, url: url, token: token) do
      normalize_outbound_result(result)
    end
  end

  def add_reaction(_provider, _channel_id, _message_id, _emoji, _connection_details),
    do: {:error, :missing_connection_details}

  @spec remove_reaction(map() | String.t() | atom(), String.t(), String.t(), String.t(), map()) ::
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
      when is_binary(channel_id) and is_binary(message_id) and is_binary(emoji) do
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
    %Incoming{
      content: incoming.text,
      channel_id: incoming.external_room_id,
      thread_id: incoming.external_thread_id,
      message_id: incoming.external_message_id,
      author_id: incoming.author && incoming.author.user_id,
      author_name: incoming.author && incoming.author.user_name,
      provider: provider,
      is_dm: (incoming.channel_meta && Map.get(incoming.channel_meta, :is_dm)) == true,
      metadata: incoming.metadata || %{}
    }
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
    agent_selection = resolve_agent_selection(config, msg, channel_id: msg.channel_id)

    with {:ok, role_ids} <- resolve_roles(msg),
         %Outgoing{} = outgoing <-
           run_pipeline(msg, role_ids: role_ids, agent_selection: agent_selection),
         :ok <- deliver_outgoing(outgoing) do
      :telemetry.execute([:zaq, :chat_bridge, :message, :processed], %{count: 1}, %{
        provider: msg.provider
      })

      persist_from_incoming(msg, outgoing.metadata)
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
    listeners =
      case listener_specs(config, bridge_id, runtime_opts) do
        {:ok, specs} -> specs
        {:error, _} -> []
      end

    {state_child_spec(config, bridge_id), listeners}
  end

  defp default_bridge_id(config), do: "#{config.provider}_#{config.id}"

  defp thread_bridge_id(channel_id, thread_id), do: "#{channel_id}_#{thread_id}"

  defp ensure_runtime_started(config, bridge_id, runtime_opts) do
    case Supervisor.lookup_state_pid(bridge_id) do
      {:ok, state_pid} ->
        State.refresh_config(state_pid, config)

      {:error, :not_running} ->
        with {:ok, listeners} <- listener_specs(config, bridge_id, runtime_opts),
             {:ok, _runtime} <-
               Supervisor.start_runtime(bridge_id, state_child_spec(config, bridge_id), listeners) do
          :ok
        else
          {:error, :already_running} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp refresh_runtime(config) do
    case Supervisor.lookup_state_pid(default_bridge_id(config)) do
      {:ok, state_pid} -> State.refresh_config(state_pid, config)
      {:error, :not_running} -> start_runtime(config)
    end
  end

  defp restart_runtime(config) do
    with :ok <- stop_runtime(config) do
      start_runtime(config)
    end
  end

  defp state_child_spec(config, bridge_id) do
    %{
      id: {State, bridge_id},
      start:
        {State, :start_link,
         [
           [
             bridge_id: bridge_id,
             config: config,
             provider: provider_to_atom(config.provider),
             handler_opts: handler_opts(config)
           ]
         ]},
      restart: :permanent,
      type: :worker
    }
  end

  defp listener_specs(config, bridge_id, runtime_opts) do
    with {:ok, adapter} <- adapter_for(config.provider),
         true <- ingress_starts_listener?(ingress_mode_for(config.provider)),
         {:ok, specs} <-
           adapter.listener_child_specs(bridge_id, listener_opts(config, bridge_id, runtime_opts)) do
      {:ok, specs}
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

  defp provider_to_atom(provider) when is_atom(provider), do: provider

  defp provider_to_atom(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> nil
  end

  defp run_pipeline(msg, opts) do
    module = pipeline_module()
    agent_selection = Keyword.get(opts, :agent_selection)
    pipeline_opts = Keyword.delete(opts, :agent_selection)

    if module == Zaq.Agent.Pipeline do
      Bridge.run_pipeline_with_node_router(
        msg,
        pipeline_opts,
        agent_selection,
        actor_from_incoming(msg),
        node_router_module()
      )
    else
      module.run(msg, pipeline_opts)
    end
  end

  @impl true
  def resolve_agent_selection(config, %Incoming{} = _incoming, opts) do
    channel_id = Keyword.get(opts, :channel_id)

    candidates = [
      {:channel_assignment, channel_assignment_agent_id(config, channel_id)},
      {:provider_default, ChannelConfig.get_provider_default_agent_id(config)},
      {:global_default, System.get_global_default_agent_id()}
    ]

    Bridge.first_active_selection(candidates)
  end

  defp channel_assignment_agent_id(config, channel_id) when is_binary(channel_id) do
    case Map.get(config, :id) || Map.get(config, "id") do
      id when is_integer(id) ->
        case RetrievalChannel.get_by_config_and_channel(id, channel_id) do
          %RetrievalChannel{configured_agent_id: configured_agent_id} -> configured_agent_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp channel_assignment_agent_id(_config, _channel_id), do: nil

  defp deliver_outgoing(outgoing) do
    module = router_module()

    if module == Router do
      event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])
      node_router_module().dispatch(event).response
    else
      module.deliver(outgoing)
    end
  end

  defp persist_from_incoming(msg, metadata) do
    module = conversations_module()

    Bridge.persist_from_incoming(
      msg,
      metadata,
      module,
      actor_from_incoming(msg),
      node_router_module()
    )
  end

  defp actor_from_incoming(%Incoming{} = incoming) do
    %{id: incoming.author_id, name: incoming.author_name, provider: incoming.provider}
  end

  defp hooks_module do
    Application.get_env(:zaq, :pipeline_hooks_module, Zaq.Hooks)
  end

  defp pipeline_module do
    Application.get_env(:zaq, :chat_bridge_pipeline_module, Zaq.Agent.Pipeline)
  end

  defp router_module do
    Application.get_env(:zaq, :chat_bridge_router_module, Router)
  end

  defp conversations_module do
    Application.get_env(:zaq, :chat_bridge_conversations_module, Zaq.Engine.Conversations)
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

      {:error, _reason} ->
        {:error, {:unsupported_provider, outgoing.provider}}
    end
  end

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
