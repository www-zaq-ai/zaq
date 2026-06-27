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

  alias Zaq.{Agent, Event, NodeRouter}
  alias Zaq.Channels.{AgentRouting, Bridge, EventNames}
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.People.IdentityResolver
  import Zaq.Engine.Messages, only: [is_present_message_id: 1]

  @callback send_reply(term(), map()) :: :ok | {:error, term()}
  @callback upsert_message(map() | atom() | String.t(), map(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback send_typing(map() | atom() | String.t(), String.t(), map()) :: :ok | {:error, term()}

  @callback add_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t() | integer(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback remove_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t() | integer(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback subscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback unsubscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback open_dm_channel(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_mailboxes(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
  @callback resolve_agent_selection(map(), Incoming.t(), keyword()) :: map() | nil
  @callback handle_webhook(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback channel_ingress_status(map()) :: {:ok, map()} | {:error, term()}
  @callback ensure_ingress_subscription(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_ingress_subscriptions(map(), map()) :: {:ok, [map()]} | {:error, term()}
  @callback delete_ingress_subscription(map(), map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks send_typing: 3,
                      upsert_message: 3,
                      add_reaction: 5,
                      remove_reaction: 5,
                      subscribe_thread_reply: 3,
                      unsubscribe_thread_reply: 3,
                      handle_webhook: 2,
                      channel_ingress_status: 1,
                      ensure_ingress_subscription: 2,
                      list_ingress_subscriptions: 2,
                      delete_ingress_subscription: 2,
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

      defdelegate route_incoming_message(msg, pipeline_opts, candidates, actor, opts \\ []),
        to: Zaq.Channels.CommunicationBridge
    end
  end

  @doc "Sends typing indicator through the provider bridge."
  @spec send_typing(atom() | String.t(), String.t() | integer()) :: :ok | {:error, term()}
  def send_typing(provider, channel_id) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <- bridge_supports?(bridge, :send_typing, 3) || :ok do
      bridge.send_typing(config, channel_id, Bridge.fetch_connection_details(provider))
    end
  end

  @doc "Adds a reaction through the provider bridge."
  @spec add_reaction(atom() | String.t(), String.t() | integer(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def add_reaction(provider, channel_id, message_id, emoji)
      when is_present_message_id(message_id) and is_binary(emoji) do
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
  @spec remove_reaction(
          atom() | String.t(),
          String.t() | integer(),
          String.t() | integer(),
          String.t(),
          map()
        ) ::
          :ok | {:error, term()}
  def remove_reaction(provider, channel_id, message_id, emoji, opts \\ %{})

  def remove_reaction(provider, channel_id, message_id, emoji, opts)
      when is_present_message_id(message_id) and is_binary(emoji) and is_map(opts) do
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

  @doc "Handles a provider webhook delivery through the configured communication bridge."
  @spec handle_webhook(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  def handle_webhook(provider, payload) when is_map(payload) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         true <- bridge_supports?(bridge, :handle_webhook, 2) || {:error, :unsupported} do
      case Bridge.fetch_channel_config(provider) do
        {:ok, config} ->
          bridge.handle_webhook(config, payload)

        {:error, {:channel_not_configured, _}} ->
          {:ok,
           %{
             provider: to_string(provider),
             handled: false,
             dropped: true,
             drop_reason: :channel_disabled
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Ensures provider ingress subscription through the configured communication bridge.

  This operation requires an enabled channel config (`fetch_channel_config/1`).
  """
  @spec ensure_ingress_subscription(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def ensure_ingress_subscription(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_channel_config(provider),
         true <-
           bridge_supports?(bridge, :ensure_ingress_subscription, 2) || {:error, :unsupported} do
      bridge.ensure_ingress_subscription(config, params)
    end
  end

  @doc """
  Lists provider ingress subscriptions through the configured communication bridge.

  This operation accepts any provider config, including disabled ones
  (`fetch_any_channel_config/1`), so operators can inspect subscriptions during
  disable/teardown workflows.
  """
  @spec list_ingress_subscriptions(atom() | String.t(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def list_ingress_subscriptions(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_any_channel_config(provider),
         true <-
           bridge_supports?(bridge, :list_ingress_subscriptions, 2) || {:error, :unsupported} do
      bridge.list_ingress_subscriptions(config, params)
    end
  end

  @doc """
  Deletes provider ingress subscription through the configured communication bridge.

  This operation accepts any provider config, including disabled ones
  (`fetch_any_channel_config/1`), so teardown can still run after a channel has
  been disabled.
  """
  @spec delete_ingress_subscription(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def delete_ingress_subscription(provider, params \\ %{}) when is_map(params) do
    with {:ok, bridge} <- Bridge.resolve_bridge(provider),
         {:ok, config} <- Bridge.fetch_any_channel_config(provider),
         true <-
           bridge_supports?(bridge, :delete_ingress_subscription, 2) || {:error, :unsupported} do
      bridge.delete_ingress_subscription(config, params)
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
    msg
    |> build_agent_pipeline_event(pipeline_opts, agent_selection, actor)
    |> dispatch_agent_pipeline_event(node_router_module)
  end

  @doc "Builds and either dispatches or only fires the canonical agent pipeline event."
  @spec route_incoming_message(Incoming.t(), keyword(), [{atom(), term()}], map(), keyword()) ::
          Outgoing.t() | :ok | {:error, term()}
  def route_incoming_message(%Incoming{} = msg, pipeline_opts, candidates, actor, opts \\ [])
      when is_list(pipeline_opts) and is_list(candidates) and is_map(actor) and is_list(opts) do
    node_router_module = Keyword.get(opts, :node_router, NodeRouter)
    pipeline_module = Keyword.get(opts, :pipeline_module, Zaq.Agent.Pipeline)
    msg = put_channel_config_id(msg, Keyword.get(opts, :channel_config_id))

    with {:ok, agent_selection} <-
           AgentRouting.resolve_selection(candidates, Keyword.get(opts, :agent_module, Agent)) do
      route_resolved_incoming_message(
        msg,
        pipeline_opts,
        agent_selection,
        actor,
        opts,
        node_router_module,
        pipeline_module
      )
    end
  end

  defp route_resolved_incoming_message(
         %Incoming{} = msg,
         pipeline_opts,
         agent_selection,
         actor,
         opts,
         node_router_module,
         Zaq.Agent.Pipeline
       ) do
    {msg, actor} = resolve_incoming_actor(msg, actor, pipeline_opts, opts)

    msg
    |> build_agent_pipeline_event(pipeline_opts, agent_selection, actor, opts)
    |> route_agent_pipeline_event(agent_selection, node_router_module)
  end

  defp route_resolved_incoming_message(
         %Incoming{} = msg,
         pipeline_opts,
         _agent_selection,
         _actor,
         _opts,
         _node_router_module,
         pipeline_module
       ) do
    pipeline_module.run(msg, pipeline_opts)
  end

  defp route_agent_pipeline_event(%Event{} = event, :none, node_router_module) do
    node_router_module.fire(event)
    :ok
  end

  defp route_agent_pipeline_event(%Event{} = event, _agent_selection, node_router_module) do
    dispatch_agent_pipeline_event(event, node_router_module)
  end

  @doc "Builds the canonical event used by channel-originated agent pipeline routing."
  @spec build_agent_pipeline_event(Incoming.t(), keyword(), map() | :none | nil, map(), keyword()) ::
          Event.t()
  def build_agent_pipeline_event(
        %Incoming{} = msg,
        pipeline_opts,
        agent_selection,
        actor,
        opts \\ []
      )
      when is_list(pipeline_opts) and is_map(actor) and is_list(opts) do
    msg
    |> Event.new(:agent,
      type: :async,
      name: EventNames.message_received(msg, routing_outcome(agent_selection), opts),
      opts: [action: :run_pipeline, pipeline_opts: pipeline_opts]
    )
    |> put_agent_selection_assign(agent_selection)
  end

  defp resolve_incoming_actor(%Incoming{} = msg, actor, pipeline_opts, opts) when is_map(actor) do
    resolver =
      Keyword.get(
        opts,
        :identity_resolver,
        Application.get_env(:zaq, :communication_bridge_identity_resolver, IdentityResolver)
      )

    resolver_opts = Keyword.merge(pipeline_opts, Keyword.get(opts, :identity_opts, []))

    case resolver.resolve(msg, resolver_opts) do
      {:ok, person} ->
        person_payload = resolver.person_payload(person)
        {%{msg | person: person_payload}, actor}

      {:error, _reason} ->
        {msg, actor}
    end
  end

  defp resolve_incoming_actor(%Incoming{} = msg, actor, _pipeline_opts, _opts), do: {msg, actor}

  defp dispatch_agent_pipeline_event(%Event{} = event, node_router_module) do
    case node_router_module.dispatch(event).response do
      %Outgoing{} = outgoing -> outgoing
      {:ok, %Outgoing{} = outgoing} -> outgoing
      {:error, _} = error -> error
      nil -> :ok
      :ok -> :ok
      other -> {:error, {:invalid_pipeline_response, other}}
    end
  end

  @spec put_agent_selection_assign(Event.t(), map() | nil) :: Event.t()
  defp put_agent_selection_assign(%Event{} = event, nil), do: event

  defp put_agent_selection_assign(%Event{} = event, :none), do: event

  defp put_agent_selection_assign(%Event{} = event, %{"agent_id" => _} = selection) do
    %{event | assigns: Map.put(event.assigns || %{}, "agent_selection", selection)}
  end

  defp put_agent_selection_assign(%Event{} = event, _selection), do: event

  defp routing_outcome(:none), do: :workflow_only
  defp routing_outcome(_agent_selection), do: :agent_requested

  defp put_channel_config_id(%Incoming{} = msg, nil), do: msg

  defp put_channel_config_id(%Incoming{} = msg, channel_config_id) do
    case normalize_channel_config_id(channel_config_id) do
      nil ->
        msg

      normalized ->
        metadata = Map.put(msg.metadata || %{}, "channel_config_id", normalized)

        telemetry_dimensions =
          metadata
          |> Map.get("telemetry_dimensions", %{})
          |> Map.put("channel_config_id", normalized)

        %{msg | metadata: Map.put(metadata, "telemetry_dimensions", telemetry_dimensions)}
    end
  end

  defp normalize_channel_config_id(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_channel_config_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "unknown" -> nil
      normalized -> normalized
    end
  end

  defp normalize_channel_config_id(_value), do: nil

  defp bridge_supports?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end
end
