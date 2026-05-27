defmodule Zaq.Channels.Api do
  @moduledoc """
  Channels role boundary for `Zaq.NodeRouter.dispatch/1` events.

  Responsibilities:

  - Handle channels-scoped event actions (`:deliver_outgoing`, `:send_typing`,
    `:fetch_profile`, `:open_dm_channel`, runtime sync, bridge availability,
    connection testing, and generic `:invoke`).
  - Resolve provider bridge modules through `Zaq.Channels.Bridge`.
  - Delegate transport-specific behavior to bridge callbacks.

  Does not own provider runtime orchestration logic; that lives in
  `Zaq.Channels.CommunicationBridge` and bridge modules.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Channels.{Bridge, ChannelConfig, CommunicationBridge, DataSourceBridge}
  alias Zaq.Channels.MessageFormatter
  alias Zaq.Engine.Messages.Outgoing
  import Zaq.Engine.Messages, only: [is_present_message_id: 1]
  alias Zaq.Event
  alias Zaq.Events.Helper
  alias Zaq.InternalBoundaries

  @supported_update_intents [:status, :reasoning, :tool_call, :stream_delta]

  @impl true
  def handle_event(%Event{} = event, :deliver_outgoing, _context) do
    bridge_module = bridge_module(event)

    with {:ok, outgoing} <- outgoing_from_event(event),
         {:ok, bridge} <- resolve_bridge(bridge_module, outgoing.provider) do
      outgoing =
        outgoing |> maybe_attach_status_message_id() |> MessageFormatter.format_outgoing()

      connection_details = bridge_module.fetch_connection_details(outgoing.provider)

      response = bridge.send_reply(outgoing, connection_details)

      %{event | response: response}
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(
        %Event{request: %{provider: provider, channel_id: channel_id}} = event,
        :send_typing,
        _context
      ) do
    bridge_module = bridge_module(event)

    with {:ok, bridge} <- resolve_bridge(bridge_module, provider),
         true <- supports_callback?(bridge, :send_typing, 3) || {:error, :unsupported} do
      config = bridge_module.fetch_channel_config(provider)
      details = bridge_module.fetch_connection_details(provider)

      case config do
        {:ok, cfg} -> %{event | response: bridge.send_typing(cfg, channel_id, details)}
        {:error, reason} -> %{event | response: {:error, reason}}
      end
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(
        %Event{} = event,
        :upsert_message,
        _context
      ) do
    bridge_module = bridge_module(event)

    with {:ok, outgoing} <- upsert_outgoing_from_event(event),
         :ok <- validate_upsert_outgoing(outgoing),
         :ok <- validate_update_intent(upsert_update_intent(outgoing)),
         {:ok, bridge} <- resolve_bridge(bridge_module, outgoing.provider),
         true <- supports_callback?(bridge, :upsert_message, 3) || {:error, :unsupported} do
      config = bridge_module.fetch_channel_config(outgoing.provider)
      details = bridge_module.fetch_connection_details(outgoing.provider)

      formatted_outgoing =
        outgoing
        |> maybe_attach_status_message_id()
        |> MessageFormatter.format_outgoing()

      case normalize_upsert_config(outgoing.provider, config) do
        {:ok, cfg} ->
          response =
            bridge.upsert_message(cfg, outgoing_to_upsert_request(formatted_outgoing), details)

          %{event | response: response}

        {:error, reason} ->
          %{event | response: {:error, reason}}
      end
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(
        %Event{request: %{provider: provider, author_id: author_id}} = event,
        :fetch_profile,
        _context
      ) do
    bridge_module = bridge_module(event)

    with {:ok, bridge} <- resolve_bridge(bridge_module, provider),
         true <- supports_callback?(bridge, :fetch_profile, 2) || {:error, :unsupported} do
      details = Map.put(bridge_module.fetch_connection_details(provider), :provider, provider)
      %{event | response: bridge.fetch_profile(author_id, details)}
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(
        %Event{request: %{provider: provider, author_id: author_id}} = event,
        :open_dm_channel,
        _context
      ) do
    bridge_module = bridge_module(event)

    with {:ok, bridge} <- resolve_bridge(bridge_module, provider),
         true <- supports_callback?(bridge, :open_dm_channel, 2) || {:error, :unsupported},
         {:ok, config} <- bridge_module.fetch_channel_config(provider) do
      bot_user_id = ChannelConfig.jido_chat_bot_user_id(config)

      details =
        bridge_module.fetch_connection_details(provider)
        |> Map.put(:provider, provider)
        |> Map.put(:bot_user_id, bot_user_id)

      %{event | response: bridge.open_dm_channel(author_id, details)}
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(
        %Event{request: %{provider: provider, config: config_params}} = event,
        :list_mailboxes,
        _context
      )
      when is_map(config_params) do
    bridge_module = bridge_module(event)

    with {:ok, bridge} <- resolve_bridge(bridge_module, provider),
         true <- supports_callback?(bridge, :list_mailboxes, 2) || {:error, :unsupported} do
      config = Map.put(config_params, :provider, to_string(provider))
      details = bridge_module.fetch_connection_details(provider)
      %{event | response: bridge.list_mailboxes(config, details)}
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(
        %Event{request: %{before_config: before_config, after_config: after_config}} = event,
        :sync_channel_runtime,
        _context
      ) do
    runtime_module = Keyword.get(event.opts, :runtime_module, CommunicationBridge)
    %{event | response: runtime_module.sync_config_runtime(before_config, after_config)}
  end

  def handle_event(
        %Event{request: %{provider: provider}} = event,
        :sync_provider_runtime,
        _context
      ) do
    runtime_module = Keyword.get(event.opts, :runtime_module, CommunicationBridge)
    %{event | response: runtime_module.sync_provider_runtime(provider)}
  end

  def handle_event(
        %Event{request: %{before_config: before_config, after_config: after_config}} = event,
        :sync_data_source_runtime,
        _context
      ) do
    runtime_module = Keyword.get(event.opts, :runtime_module, DataSourceBridge)
    %{event | response: runtime_module.sync_config_runtime(before_config, after_config)}
  end

  def handle_event(
        %Event{request: %{provider: provider}} = event,
        :sync_data_source_provider_runtime,
        _context
      ) do
    runtime_module = Keyword.get(event.opts, :runtime_module, DataSourceBridge)
    %{event | response: runtime_module.sync_provider_runtime(provider)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_auth_handshake,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.auth_handshake(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_list_resources,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.list_resources(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, resource: resource, params: params}} = event,
        :data_source_download_resource,
        _context
      )
      when is_map(resource) and is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.download_resource(provider, resource, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_setup_listener,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.setup_listener(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_list_files,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.list_files(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_create_file,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.create_file(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_get_file,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.get_file(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_update_file,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.update_file(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_delete_file,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.delete_file(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_search_files,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.search_files(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_download_document,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.download_document(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_list_permissions,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.list_permissions(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_teardown_listener,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.teardown_listener(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_channel_stats,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.channel_stats(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_export_options,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.export_options(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_inspect,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_inspect(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_get,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_get(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_create,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_create(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_add_tab,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_add_tab(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_update_values,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_update_values(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_append_values,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_append_values(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_clear_values,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_clear_values(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_sheet_delete_tab,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.sheet_delete_tab(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_oauth_authorize_url,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.oauth_authorize_url(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_oauth_exchange_code,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.oauth_exchange_code(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :data_source_oauth_refresh_token,
        _context
      )
      when is_map(params) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.oauth_refresh_token(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider}} = event,
        :data_source_oauth_default_scopes,
        _context
      ) do
    data_source_module = Keyword.get(event.opts, :data_source_bridge_module, DataSourceBridge)
    %{event | response: data_source_module.oauth_default_scopes(provider)}
  end

  def handle_event(
        %Event{request: %{type: type, provider: provider, payload: payload}} = event,
        :webhook_delivered,
        _context
      )
      when type in ["data_source", "conversation"] and is_map(payload) do
    {module_key, default_module} =
      if type == "data_source" do
        {:data_source_bridge_module, DataSourceBridge}
      else
        {:communication_bridge_module, CommunicationBridge}
      end

    handler_module = Keyword.get(event.opts, module_key, default_module)
    %{event | response: handler_module.handle_webhook(provider, payload)}
  end

  def handle_event(%Event{request: %{platform: platform}} = event, :bridge_available, _context)
      when is_binary(platform) do
    bridge_module = bridge_module(event)
    %{event | response: not is_nil(bridge_module.bridge_for(platform))}
  end

  def handle_event(
        %Event{request: %{provider: provider}} = event,
        :channel_capability_snapshot,
        _context
      ) do
    bridge_module = bridge_module(event)
    %{event | response: bridge_module.capability_snapshot(provider)}
  end

  def handle_event(
        %Event{request: %{provider: provider} = request} = event,
        :channel_ingress_status,
        _context
      ) do
    bridge_module = bridge_module(event)

    with {:ok, bridge} <- resolve_bridge(bridge_module, provider),
         true <- supports_callback?(bridge, :channel_ingress_status, 1) || {:error, :unsupported},
         {:ok, config} <- ingress_status_config(bridge_module, provider, request) do
      %{event | response: bridge.channel_ingress_status(config)}
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :channel_ensure_ingress_subscription,
        _context
      )
      when is_map(params) do
    runtime_module = Keyword.get(event.opts, :runtime_module, CommunicationBridge)
    %{event | response: runtime_module.ensure_ingress_subscription(provider, params)}
  end

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :channel_delete_ingress_subscription,
        _context
      )
      when is_map(params) do
    runtime_module = Keyword.get(event.opts, :runtime_module, CommunicationBridge)
    %{event | response: runtime_module.delete_ingress_subscription(provider, params)}
  end

  def handle_event(
        %Event{request: %{config: %ChannelConfig{} = config, channel_id: channel_id}} = event,
        :test_connection,
        _context
      )
      when is_binary(channel_id) do
    bridge_module = bridge_module(event)

    with {:ok, bridge} <- resolve_bridge(bridge_module, config.provider),
         true <- supports_callback?(bridge, :test_connection, 2) || {:error, :unsupported} do
      %{event | response: bridge.test_connection(config, channel_id)}
    else
      {:error, reason} -> %{event | response: {:error, reason}}
    end
  end

  def handle_event(%Event{} = event, :incoming_async_hop, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end

  defp outgoing_from_event(%Event{request: %Outgoing{} = outgoing}), do: {:ok, outgoing}
  defp outgoing_from_event(%Event{response: %Outgoing{} = outgoing}), do: {:ok, outgoing}
  defp outgoing_from_event(_event), do: {:error, {:invalid_request, :missing_outgoing_payload}}

  defp upsert_outgoing_from_event(%Event{request: %Outgoing{} = outgoing}), do: {:ok, outgoing}

  defp upsert_outgoing_from_event(%Event{request: request}) when is_map(request) do
    {:ok, map_to_upsert_outgoing(request)}
  end

  defp upsert_outgoing_from_event(_event),
    do: {:error, {:invalid_request, :missing_upsert_payload}}

  defp resolve_bridge(bridge_module, provider) when is_atom(bridge_module) do
    case bridge_module.bridge_for(provider) do
      nil -> {:error, {:no_bridge, provider}}
      bridge -> {:ok, bridge}
    end
  end

  defp supports_callback?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end

  defp bridge_module(%Event{opts: opts}) when is_list(opts) do
    Keyword.get(opts, :bridge_module) || Keyword.get(opts, :communication_bridge_module, Bridge)
  end

  defp bridge_module(_event), do: Bridge

  defp ingress_status_config(_bridge_module, _provider, %{config: %ChannelConfig{} = config}),
    do: {:ok, config}

  defp ingress_status_config(_bridge_module, _provider, %{config: config}) when is_map(config),
    do: {:ok, config}

  defp ingress_status_config(bridge_module, provider, _request),
    do: bridge_module.fetch_channel_config(provider)

  defp validate_update_intent(nil), do: :ok

  defp validate_update_intent(intent) when is_atom(intent) do
    if intent in @supported_update_intents,
      do: :ok,
      else: {:error, :unsupported_update_intent}
  end

  defp validate_update_intent(intent) when is_binary(intent) do
    intent
    |> String.to_existing_atom()
    |> validate_update_intent()
  rescue
    ArgumentError -> {:error, :unsupported_update_intent}
  end

  defp validate_update_intent(_), do: {:error, :unsupported_update_intent}

  defp validate_upsert_outgoing(%Outgoing{} = outgoing) do
    metadata = if is_map(outgoing.metadata), do: outgoing.metadata, else: %{}
    request_id = Map.get(metadata, :request_id) || Map.get(metadata, "request_id")

    if Enum.all?(
         [outgoing.provider, outgoing.channel_id, request_id, outgoing.body],
         &Helper.present?/1
       ) do
      :ok
    else
      {:error, {:invalid_request, :missing_upsert_fields}}
    end
  end

  defp maybe_attach_status_message_id(%Outgoing{} = outgoing) do
    metadata = if is_map(outgoing.metadata), do: outgoing.metadata, else: %{}

    if Helper.present?(Map.get(metadata, :message_id) || Map.get(metadata, "message_id")) do
      outgoing
    else
      case Map.get(metadata, :status_message_id) || Map.get(metadata, "status_message_id") do
        message_id when is_present_message_id(message_id) ->
          %{outgoing | metadata: Map.put(metadata, :message_id, message_id)}

        _ ->
          %{outgoing | metadata: metadata}
      end
    end
  end

  defp outgoing_to_upsert_request(%Outgoing{} = outgoing) do
    metadata = if is_map(outgoing.metadata), do: outgoing.metadata, else: %{}

    %{
      provider: outgoing.provider,
      channel_id: outgoing.channel_id,
      thread_id: outgoing.thread_id,
      body: outgoing.body,
      request_id: Map.get(metadata, :request_id) || Map.get(metadata, "request_id"),
      session_id: Map.get(metadata, :session_id) || Map.get(metadata, "session_id"),
      intent_meta: Map.get(metadata, :intent_meta) || Map.get(metadata, "intent_meta"),
      update_intent: Map.get(metadata, :update_intent) || Map.get(metadata, "update_intent"),
      message_id: Map.get(metadata, :message_id) || Map.get(metadata, "message_id"),
      format: Map.get(metadata, :format)
    }
  end

  defp map_to_upsert_outgoing(request) when is_map(request) do
    metadata = %{
      request_id: fetch(request, :request_id),
      session_id: fetch(request, :session_id),
      status_message_id: fetch(request, :status_message_id),
      update_intent: fetch(request, :update_intent),
      intent_meta: fetch(request, :intent_meta),
      message_id: fetch(request, :message_id)
    }

    %Outgoing{
      provider: fetch(request, :provider),
      channel_id: fetch(request, :channel_id),
      thread_id: fetch(request, :thread_id),
      body: fetch(request, :body),
      metadata: metadata
    }
  end

  defp upsert_update_intent(%Outgoing{} = outgoing) do
    metadata = if is_map(outgoing.metadata), do: outgoing.metadata, else: %{}
    Map.get(metadata, :update_intent) || Map.get(metadata, "update_intent")
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_upsert_config(provider, {:error, _reason}) when provider in [:web, "web"],
    do: {:ok, %{provider: "web"}}

  defp normalize_upsert_config(_provider, config), do: config
end
