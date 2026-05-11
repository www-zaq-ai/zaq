defmodule Zaq.Channels.DataSourceBridge do
  @moduledoc """
  DataSource-domain bridge routing and delegation helpers.

  This module is the Channels boundary for DataSource operations (auth,
  resource listing/download, listener setup/teardown). It resolves provider
  bridge modules via `Zaq.Channels.Bridge` and delegates transport-specific
  behavior to the concrete bridge implementation.
  """

  alias Zaq.Channels.Bridge

  @callback auth_handshake(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback list_resources(map(), map()) :: {:ok, list()} | {:error, term()}
  @callback download_resource(map(), map(), map()) :: {:ok, term()} | {:error, term()}
  @callback setup_listener(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback teardown_listener(map(), map()) :: :ok | {:error, term()}

  @doc "Runs provider auth handshake through the configured DataSource bridge."
  @spec auth_handshake(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def auth_handshake(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :auth_handshake, 2) || {:error, :unsupported} do
      bridge.auth_handshake(config, params)
    end
  end

  @doc "Lists provider resources through the configured DataSource bridge."
  @spec list_resources(atom() | String.t(), map()) :: {:ok, list()} | {:error, term()}
  def list_resources(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :list_resources, 2) || {:error, :unsupported} do
      bridge.list_resources(config, params)
    end
  end

  @doc "Downloads a provider resource through the configured DataSource bridge."
  @spec download_resource(atom() | String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  def download_resource(provider, resource, params \\ %{})
      when is_map(resource) and is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :download_resource, 3) || {:error, :unsupported} do
      bridge.download_resource(config, resource, params)
    end
  end

  @doc "Sets up a provider listener through the configured DataSource bridge."
  @spec setup_listener(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def setup_listener(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :setup_listener, 2) || {:error, :unsupported} do
      bridge.setup_listener(config, params)
    end
  end

  @doc "Tears down a provider listener through the configured DataSource bridge."
  @spec teardown_listener(atom() | String.t(), map()) :: :ok | {:error, term()}
  def teardown_listener(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- supports_callback?(bridge, :teardown_listener, 2) || {:error, :unsupported} do
      bridge.teardown_listener(config, params)
    end
  end

  @doc "Synchronizes runtime processes when a datasource config changes."
  @spec sync_config_runtime(map() | nil, map()) :: :ok | {:error, term()}
  def sync_config_runtime(before_config, %{provider: provider} = after_config) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider) do
      if supports_callback?(bridge, :sync_runtime, 2) do
        bridge.sync_runtime(before_config, after_config)
      else
        Bridge.sync_config_runtime(before_config, after_config)
      end
    end
  end

  @doc "Synchronizes runtime from the canonical DB config for provider."
  @spec sync_provider_runtime(atom() | String.t()) :: :ok | {:error, term()}
  def sync_provider_runtime(provider) do
    with {:ok, config} <- Bridge.fetch_any_channel_config(provider),
         {:ok, bridge} <- Bridge.resolve_bridge(provider) do
      Bridge.dispatch_provider_runtime_sync(bridge, config)
    end
  end

  defp supports_callback?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end
end
