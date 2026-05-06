defmodule Zaq.RuntimeDeps do
  @moduledoc """
  Centralized runtime dependency indirection for modules that need injectable collaborators.

  This module wraps `Application.get_env/3` lookups behind small accessors so callers
  can depend on stable function names while tests can override the underlying modules
  via `Application.put_env/3`.

  The defaults are production-safe implementations and can be overridden per environment.
  """

  alias Zaq.Channels.ChannelConfig
  alias Zaq.NodeRouter

  @doc "Returns the NodeRouter module used for cross-service dispatch."
  @spec node_router() :: module()
  def node_router, do: get(:node_router, NodeRouter)

  @doc "Returns the NodeRouter module used by ChatLive async pipeline calls."
  @spec chat_live_node_router() :: module()
  def chat_live_node_router, do: get(:chat_live_node_router_module, NodeRouter)

  @doc "Returns the channel config module used by ChannelsLive."
  @spec channel_config() :: module()
  def channel_config, do: get(:channels_live_channel_config_module, ChannelConfig)

  @doc "Returns the Mattermost API adapter module used by ChannelsLive."
  @spec mattermost_api() :: module()
  def mattermost_api, do: get(:channels_live_mattermost_api_module, Zaq.Channels.MattermostAdmin)

  @doc "Returns the HTTP client module used by ChannelsLive post browsing."
  @spec http_client() :: module()
  def http_client, do: get(:channels_live_http_client, Req)

  @doc "Generic environment lookup helper with default fallback."
  @spec get(atom(), any()) :: any()
  def get(key, default), do: Application.get_env(:zaq, key, default)
end
