defmodule Zaq.Channels.CommunicationBridge do
  @moduledoc """
  Communication-domain bridge routing and delegation helpers.

  Responsibilities:

  - Resolve provider -> bridge mappings through `Zaq.Channels.Bridge`.
  - Delegate provider interaction operations (typing/reactions/thread watches).
  - Coordinate runtime sync delegation (`sync_config_runtime/2`,
    `sync_provider_runtime/1`) with fallback behavior when optional callbacks
    are not implemented by a bridge.
  - Build and dispatch agent pipeline events through `Zaq.NodeRouter` for
    channel-originated incoming messages.
  - Enforce conversation-agent eligibility for selection helpers.

  This module is stateless and does not own bridge runtime process internals;
  runtime process construction and transport behavior belong to each bridge.
  """

  alias Zaq.{Agent, Event}
  alias Zaq.Channels.Bridge
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Utils.ParseUtils

  @callback send_reply(term(), map()) :: :ok | {:error, term()}
  @callback send_typing(map() | atom() | String.t(), String.t(), map()) :: :ok | {:error, term()}

  @callback add_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback remove_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback subscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback unsubscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback open_dm_channel(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_mailboxes(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
  @callback resolve_agent_selection(map(), Incoming.t(), keyword()) :: map() | nil

  @optional_callbacks send_typing: 3,
                      add_reaction: 5,
                      remove_reaction: 5,
                      subscribe_thread_reply: 3,
                      unsubscribe_thread_reply: 3,
                      open_dm_channel: 2,
                      fetch_profile: 2,
                      list_mailboxes: 2,
                      resolve_agent_selection: 3

  defmacro __using__(_opts) do
    quote do
      defdelegate run_pipeline_with_node_router(
                    msg,
                    pipeline_opts,
                    agent_selection,
                    actor,
                    node_router_module
                  ),
                  to: Zaq.Channels.CommunicationBridge

      defdelegate first_active_selection(candidates, agent_module \\ Zaq.Agent),
        to: Zaq.Channels.CommunicationBridge
    end
  end

  @doc "Sends typing indicator through the provider bridge."
  @spec send_typing(atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def send_typing(provider, channel_id) when is_binary(channel_id) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- bridge_supports?(bridge, :send_typing, 3) || :ok do
      bridge.send_typing(config, channel_id, Bridge.fetch_connection_details(provider))
    end
  end

  @doc "Adds a reaction through the provider bridge."
  @spec add_reaction(atom() | String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def add_reaction(provider, channel_id, message_id, emoji)
      when is_binary(channel_id) and is_binary(message_id) and is_binary(emoji) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider) do
      bridge.add_reaction(
        config,
        channel_id,
        message_id,
        emoji,
        Bridge.fetch_connection_details(provider)
      )
    end
  end

  @doc "Removes a reaction through the provider bridge."
  @spec remove_reaction(atom() | String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def remove_reaction(provider, channel_id, message_id, emoji, opts \\ %{})

  def remove_reaction(provider, channel_id, message_id, emoji, opts)
      when is_binary(channel_id) and is_binary(message_id) and is_binary(emoji) and is_map(opts) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider) do
      bridge.remove_reaction(
        config,
        channel_id,
        message_id,
        emoji,
        Map.merge(Bridge.fetch_connection_details(provider), opts)
      )
    end
  end

  @doc "Subscribes to thread replies via provider bridge."
  @spec subscribe_thread_reply(atom() | String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def subscribe_thread_reply(provider, channel_id, thread_id)
      when is_binary(channel_id) and is_binary(thread_id) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider) do
      bridge.subscribe_thread_reply(config, channel_id, thread_id)
    end
  end

  @doc "Unsubscribes from thread replies via provider bridge."
  @spec unsubscribe_thread_reply(atom() | String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def unsubscribe_thread_reply(provider, channel_id, thread_id)
      when is_binary(channel_id) and is_binary(thread_id) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider) do
      bridge.unsubscribe_thread_reply(config, channel_id, thread_id)
    end
  end

  @doc "Synchronizes runtime processes when a channel config changes via Bridge resolution."
  @spec sync_config_runtime(map() | nil, map()) :: :ok | {:error, term()}
  def sync_config_runtime(before_config, %{provider: provider} = after_config) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider) do
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
    with {:ok, config} <- Bridge.fetch_any_channel_config(provider),
         {:ok, bridge} <- Bridge.resolve_bridge(provider) do
      Bridge.dispatch_provider_runtime_sync(bridge, config)
    end
  end

  @doc "Runs bridge-specific connection test for a channel config."
  @spec test_connection(map(), String.t()) :: {:ok, term()} | {:error, term()}
  def test_connection(%{provider: provider} = config, channel_id) when is_binary(channel_id) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         true <- bridge_supports?(bridge, :test_connection, 2) || {:error, :unsupported} do
      bridge.test_connection(config, channel_id)
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

  defp with_bridge_runtime(%{provider: provider} = config, fun)
       when fun in [:start_runtime, :stop_runtime] do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         true <- bridge_supports?(bridge, fun, 1) || :unsupported do
      apply(bridge, fun, [config])
    else
      :unsupported -> :ok
    end
  end

  @doc "Runs pipeline through NodeRouter and normalizes response shape."
  @spec run_pipeline_with_node_router(Incoming.t(), keyword(), map() | nil, map(), module()) ::
          Outgoing.t() | {:error, term()}
  def run_pipeline_with_node_router(
        %Incoming{} = msg,
        pipeline_opts,
        agent_selection,
        actor,
        node_router_module
      )
      when is_list(pipeline_opts) and is_map(actor) and is_atom(node_router_module) do
    event =
      Event.new(
        msg,
        :agent,
        actor: actor,
        type: :async,
        opts: [action: :run_pipeline, pipeline_opts: pipeline_opts]
      )
      |> put_agent_selection_assign(agent_selection)

    case node_router_module.dispatch(event).response do
      %Outgoing{} = outgoing -> outgoing
      {:ok, %Outgoing{} = outgoing} -> outgoing
      {:error, _} = error -> error
      nil -> :ok
      :ok -> :ok
      other -> {:error, {:invalid_pipeline_response, other}}
    end
  end

  @doc "Returns first conversation-eligible candidate agent selection from ordered candidates."
  @spec first_active_selection([{atom(), term()}], module()) :: map() | nil
  def first_active_selection(candidates, agent_module \\ Agent)

  def first_active_selection(candidates, agent_module)
      when is_list(candidates) and is_atom(agent_module) do
    Enum.find_value(candidates, fn {source, candidate_id} ->
      with {:ok, id} <- ParseUtils.parse_int_strict(candidate_id),
           {:ok, _agent} <- agent_module.get_conversation_enabled_agent(id) do
        %{"agent_id" => id, "source" => Atom.to_string(source)}
      else
        _ -> nil
      end
    end)
  end

  @spec put_agent_selection_assign(Event.t(), map() | nil) :: Event.t()
  defp put_agent_selection_assign(%Event{} = event, nil), do: event

  defp put_agent_selection_assign(%Event{} = event, %{"agent_id" => _} = selection) do
    %{event | assigns: Map.put(event.assigns || %{}, "agent_selection", selection)}
  end

  defp put_agent_selection_assign(%Event{} = event, _selection), do: event

  defp bridge_supports?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end
end
