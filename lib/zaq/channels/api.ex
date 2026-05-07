defmodule Zaq.Channels.Api do
  @moduledoc """
  Channels role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.Router
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{request: %Outgoing{} = outgoing} = event, :deliver_outgoing, _context) do
    bridge_module = Keyword.get(event.opts, :communication_bridge_module, CommunicationBridge)
    %{event | response: bridge_module.deliver(outgoing)}
  end

  def handle_event(
        %Event{request: %{before_config: before_config, after_config: after_config}} = event,
        :sync_channel_runtime,
        _context
      ) do
    bridge_module = Keyword.get(event.opts, :communication_bridge_module, CommunicationBridge)
    %{event | response: bridge_module.sync_config_runtime(before_config, after_config)}
  end

  def handle_event(
        %Event{request: %{provider: provider}} = event,
        :sync_provider_runtime,
        _context
      ) do
    bridge_module = Keyword.get(event.opts, :communication_bridge_module, CommunicationBridge)
    %{event | response: bridge_module.sync_provider_runtime(provider)}
  end

  def handle_event(%Event{request: %{platform: platform}} = event, :bridge_available, _context)
      when is_binary(platform) do
    bridge_module = Keyword.get(event.opts, :communication_bridge_module, CommunicationBridge)
    %{event | response: not is_nil(bridge_module.bridge_for(platform))}
  end

  def handle_event(
        %Event{request: %{config: %ChannelConfig{} = config, channel_id: channel_id}} = event,
        :test_connection,
        _context
      )
      when is_binary(channel_id) do
    router_module = Keyword.get(event.opts, :router_module, Router)
    %{event | response: router_module.test_connection(config, channel_id)}
  end

  def handle_event(%Event{} = event, :incoming_async_hop, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end
end
