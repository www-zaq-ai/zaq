defmodule Zaq.Channels.CommunicationBridge do
  @moduledoc """
  Communication-domain bridge routing and delegation helpers.

  This module resolves provider->bridge mappings, fetches channel connection
  details, and delegates outbound runtime/interaction callbacks to bridge
  modules.
  """

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing

  @smtp_provider "email:smtp"
  @imap_provider "email:imap"

  @doc "Returns the configured bridge module for provider."
  @spec bridge_for(atom() | String.t()) :: module() | nil
  def bridge_for(provider) when is_binary(provider) do
    provider
    |> provider_to_bridge_key()
    |> case do
      nil -> nil
      key -> bridge_for(key)
    end
  end

  def bridge_for(provider) when is_atom(provider) do
    :zaq
    |> Application.get_env(:channels, %{})
    |> get_in([provider, :bridge])
  end

  @doc "Maps provider string keys to configured bridge keys."
  @spec provider_to_bridge_key(String.t()) :: atom() | nil
  def provider_to_bridge_key(@smtp_provider), do: :email
  def provider_to_bridge_key(@imap_provider), do: :email

  def provider_to_bridge_key(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> nil
  end

  @doc "Delivers `%Outgoing{}` to the correct provider bridge."
  @spec deliver(Outgoing.t()) :: :ok | {:error, term()}
  def deliver(%Outgoing{} = outgoing) do
    case bridge_for(outgoing.provider) do
      nil ->
        {:error, {:no_bridge, outgoing.provider}}

      bridge ->
        connection_details = fetch_connection_details(outgoing.provider)
        bridge.send_reply(outgoing, connection_details)
    end
  end

  @doc "Sends typing indicator through the provider bridge."
  @spec send_typing(atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def send_typing(provider, channel_id) when is_binary(channel_id) do
    with {:ok, bridge} <- resolve_bridge(provider),
         {:ok, config} <- fetch_channel_config(provider),
         true <- bridge_supports?(bridge, :send_typing, 3) || :ok do
      bridge.send_typing(config, channel_id, fetch_connection_details(provider))
    end
  end

  @doc "Adds a reaction through the provider bridge."
  @spec add_reaction(atom() | String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def add_reaction(provider, channel_id, message_id, emoji)
      when is_binary(channel_id) and is_binary(message_id) and is_binary(emoji) do
    with {:ok, bridge} <- resolve_bridge(provider),
         {:ok, config} <- fetch_channel_config(provider) do
      bridge.add_reaction(
        config,
        channel_id,
        message_id,
        emoji,
        fetch_connection_details(provider)
      )
    end
  end

  @doc "Removes a reaction through the provider bridge."
  @spec remove_reaction(atom() | String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def remove_reaction(provider, channel_id, message_id, emoji, opts \\ %{})

  def remove_reaction(provider, channel_id, message_id, emoji, opts)
      when is_binary(channel_id) and is_binary(message_id) and is_binary(emoji) and is_map(opts) do
    with {:ok, bridge} <- resolve_bridge(provider),
         {:ok, config} <- fetch_channel_config(provider) do
      bridge.remove_reaction(
        config,
        channel_id,
        message_id,
        emoji,
        Map.merge(fetch_connection_details(provider), opts)
      )
    end
  end

  @doc "Subscribes to thread replies via provider bridge."
  @spec subscribe_thread_reply(atom() | String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def subscribe_thread_reply(provider, channel_id, thread_id)
      when is_binary(channel_id) and is_binary(thread_id) do
    with {:ok, bridge} <- resolve_bridge(provider),
         {:ok, config} <- fetch_channel_config(provider) do
      bridge.subscribe_thread_reply(config, channel_id, thread_id)
    end
  end

  @doc "Unsubscribes from thread replies via provider bridge."
  @spec unsubscribe_thread_reply(atom() | String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def unsubscribe_thread_reply(provider, channel_id, thread_id)
      when is_binary(channel_id) and is_binary(thread_id) do
    with {:ok, bridge} <- resolve_bridge(provider),
         {:ok, config} <- fetch_channel_config(provider) do
      bridge.unsubscribe_thread_reply(config, channel_id, thread_id)
    end
  end

  @doc "Synchronizes runtime processes when a channel config changes."
  @spec sync_config_runtime(map() | nil, map()) :: :ok | {:error, term()}
  def sync_config_runtime(before_config, %{provider: provider} = after_config) do
    with {:ok, bridge} <- resolve_bridge(provider) do
      if bridge_supports?(bridge, :sync_runtime, 2) do
        bridge.sync_runtime(before_config, after_config)
      else
        fallback_sync_config_runtime(before_config, after_config)
      end
    end
  end

  @doc "Synchronizes runtime processes from canonical DB config for provider."
  @spec sync_provider_runtime(atom() | String.t()) :: :ok | {:error, term()}
  def sync_provider_runtime(provider) do
    with {:ok, config} <- fetch_any_channel_config(provider),
         {:ok, bridge} <- resolve_bridge(provider) do
      dispatch_provider_runtime_sync(bridge, config)
    end
  end

  @doc "Runs bridge-specific connection test for a channel config."
  @spec test_connection(map(), String.t()) :: {:ok, term()} | {:error, term()}
  def test_connection(%{provider: provider} = config, channel_id) when is_binary(channel_id) do
    with {:ok, bridge} <- resolve_bridge(provider),
         true <- bridge_supports?(bridge, :test_connection, 2) || {:error, :unsupported} do
      bridge.test_connection(config, channel_id)
    end
  end

  @doc "Fetches connection details by provider."
  @spec fetch_connection_details(atom() | String.t()) :: map()
  def fetch_connection_details(:web), do: %{}

  def fetch_connection_details(provider) do
    case ChannelConfig.get_by_provider(to_string(provider)) do
      nil -> %{}
      config -> %{url: config.url, token: config.token}
    end
  end

  @doc "Fetches enabled channel config by provider."
  @spec fetch_channel_config(atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_channel_config(provider) do
    case ChannelConfig.get_by_provider(to_string(provider)) do
      nil -> {:error, {:channel_not_configured, provider}}
      config -> {:ok, config}
    end
  end

  @doc "Fetches channel config by provider, including disabled entries."
  @spec fetch_any_channel_config(atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_any_channel_config(provider) do
    case ChannelConfig.get_any_by_provider(to_string(provider)) do
      nil -> {:error, {:channel_not_configured, provider}}
      config -> {:ok, config}
    end
  end

  @doc "Resolves configured bridge for provider."
  @spec resolve_bridge(atom() | String.t()) :: {:ok, module()} | {:error, term()}
  def resolve_bridge(provider) do
    case bridge_for(provider) do
      nil -> {:error, {:no_bridge, provider}}
      bridge -> {:ok, bridge}
    end
  end

  @doc "Delegates provider runtime sync to bridge callback or fallback runtime hooks."
  @spec dispatch_provider_runtime_sync(module(), map()) :: :ok | {:error, term()}
  def dispatch_provider_runtime_sync(bridge, config) do
    if bridge_supports?(bridge, :sync_provider_runtime, 1) do
      bridge.sync_provider_runtime(config)
    else
      fallback_sync_provider_runtime(config)
    end
  end

  defp fallback_sync_config_runtime(nil, %{enabled: true} = config),
    do: with_bridge_runtime(config, :start_runtime)

  defp fallback_sync_config_runtime(nil, %{enabled: false}), do: :ok

  defp fallback_sync_config_runtime(%{enabled: true}, %{enabled: false} = config),
    do: with_bridge_runtime(config, :stop_runtime)

  defp fallback_sync_config_runtime(%{enabled: false}, %{enabled: true} = config),
    do: with_bridge_runtime(config, :start_runtime)

  defp fallback_sync_config_runtime(_before, _after), do: :ok

  defp fallback_sync_provider_runtime(config) do
    if config.enabled do
      with_bridge_runtime(config, :start_runtime)
    else
      with_bridge_runtime(config, :stop_runtime)
    end
  end

  defp with_bridge_runtime(%{provider: provider} = config, fun)
       when fun in [:start_runtime, :stop_runtime] do
    with {:ok, bridge} <- resolve_bridge(provider),
         true <- bridge_supports?(bridge, fun, 1) || :unsupported do
      apply(bridge, fun, [config])
    else
      :unsupported -> :ok
    end
  end

  defp bridge_supports?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end
end
