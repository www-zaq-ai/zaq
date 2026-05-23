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
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{} = event, :deliver_outgoing, _context) do
    bridge_module = bridge_module(event)

    with {:ok, outgoing} <- outgoing_from_event(event),
         {:ok, bridge} <- resolve_bridge(bridge_module, outgoing.provider) do
      connection_details = bridge_module.fetch_connection_details(outgoing.provider)
      %{event | response: bridge.send_reply(outgoing, connection_details)}
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
end
