defmodule Zaq.Channels.Router do
  @moduledoc """
  Stateless outbound router for all ZAQ channels.

  Most communication-domain routing/delegation logic lives in
  `Zaq.Channels.CommunicationBridge`. This module is kept as the stable public
  entrypoint while downstream call-site migrations complete.
  """

  alias Zaq.Channels.{ChannelConfig, CommunicationBridge}
  alias Zaq.Engine.Messages.Outgoing

  @doc """
  Delivers `%Outgoing{}` to the correct bridge.

  Returns `:ok` on success or `{:error, reason}` on failure.
  Returns `{:error, {:no_bridge, provider}}` if no bridge is configured for the provider.
  """
  @spec deliver(Outgoing.t()) :: :ok | {:error, term()}
  defdelegate deliver(outgoing), to: CommunicationBridge

  @doc "Returns the configured bridge module for provider."
  @spec bridge_for(atom() | String.t()) :: module() | nil
  defdelegate bridge_for(provider), to: CommunicationBridge

  @doc "Sends typing indicator through the provider bridge."
  @spec send_typing(atom() | String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate send_typing(provider, channel_id), to: CommunicationBridge

  @doc "Adds a reaction through the provider bridge."
  @spec add_reaction(atom() | String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defdelegate add_reaction(provider, channel_id, message_id, emoji), to: CommunicationBridge

  @doc "Removes a reaction through the provider bridge."
  @spec remove_reaction(atom() | String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  defdelegate remove_reaction(provider, channel_id, message_id, emoji, opts \\ %{}),
    to: CommunicationBridge

  @doc "Subscribes to thread replies via provider bridge."
  @spec subscribe_thread_reply(atom() | String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defdelegate subscribe_thread_reply(provider, channel_id, thread_id), to: CommunicationBridge

  @doc "Unsubscribes from thread replies via provider bridge."
  @spec unsubscribe_thread_reply(atom() | String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defdelegate unsubscribe_thread_reply(provider, channel_id, thread_id), to: CommunicationBridge

  @doc "Synchronizes runtime processes when a channel config changes."
  @spec sync_config_runtime(map() | nil, map()) :: :ok | {:error, term()}
  defdelegate sync_config_runtime(before_config, after_config), to: CommunicationBridge

  @doc "Synchronizes runtime processes from canonical DB config for provider."
  @spec sync_provider_runtime(atom() | String.t()) :: :ok | {:error, term()}
  defdelegate sync_provider_runtime(provider), to: CommunicationBridge

  @doc """
  Opens or returns the existing DM channel between the bot and a user.

  Looks up `bot_user_id` from the channel config and delegates to the provider bridge.
  Returns `{:ok, dm_channel_id}` on success.
  """
  @spec open_dm_channel(atom() | String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def open_dm_channel(platform, author_id) when is_binary(author_id) do
    with {:ok, bridge} <- CommunicationBridge.resolve_bridge(platform),
         true <- bridge_supports?(bridge, :open_dm_channel, 2) || {:error, :unsupported} do
      config = ChannelConfig.get_by_provider(to_string(platform))
      bot_user_id = config && ChannelConfig.jido_chat_bot_user_id(config)

      details =
        CommunicationBridge.fetch_connection_details(platform)
        |> Map.put(:provider, platform)
        |> Map.put(:bot_user_id, bot_user_id)

      bridge.open_dm_channel(author_id, details)
    end
  end

  def fetch_profile("web", author_id), do: {:ok, %{id: author_id, name: "Web User"}}

  @doc "Fetches a user's canonical profile from the platform bridge."
  @spec fetch_profile(atom() | String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_profile(platform, author_id) when is_binary(author_id) do
    with {:ok, bridge} <- CommunicationBridge.resolve_bridge(platform),
         true <- bridge_supports?(bridge, :fetch_profile, 2) || {:error, :unsupported} do
      bridge.fetch_profile(
        author_id,
        Map.put(CommunicationBridge.fetch_connection_details(platform), :provider, platform)
      )
    end
  end

  @doc "Runs bridge-specific connection test for a channel config."
  @spec test_connection(map(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate test_connection(config, channel_id), to: CommunicationBridge

  @doc "Lists available mailboxes for an email provider using bridge routing."
  @spec list_mailboxes(atom() | String.t(), map()) :: {:ok, [String.t()]} | {:error, term()}
  def list_mailboxes(provider, config_params) when is_map(config_params) do
    with {:ok, bridge} <- CommunicationBridge.resolve_bridge(provider),
         true <- bridge_supports?(bridge, :list_mailboxes, 2) || {:error, :unsupported} do
      bridge.list_mailboxes(
        Map.put(config_params, :provider, to_string(provider)),
        CommunicationBridge.fetch_connection_details(provider)
      )
    end
  end

  defp bridge_supports?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end
end
