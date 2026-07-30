defmodule Zaq.Channels.CommunicationBridge do
  @moduledoc """
  Communication-domain bridge routing and delegation helpers.

  Responsibilities:

  - Resolve provider -> bridge mappings through `Zaq.Channels.Bridge`.
  - Delegate provider interaction operations (typing/reactions/thread watches).
  - Coordinate runtime sync delegation (`sync_config_runtime/2`,
    `sync_provider_runtime/1`) with fallback behavior when optional callbacks
    are not implemented by a bridge.
  - Build and dispatch events through `Zaq.NodeRouter` for channel-originated
    activity: agent pipeline events for incoming messages, and message ratings
    once a channel has mapped its provider vocabulary to a ZAQ rating.
  - Enforce conversation-agent eligibility for selection helpers.

  This module is stateless and does not own bridge runtime process internals;
  runtime process construction and transport behavior belong to each bridge.
  """

  alias Zaq.Channels.Bridge
  alias Zaq.Channels.EventNames
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter

  import Zaq.Engine.Messages, only: [is_present_message_id: 1]

  # `{:ok, receipt}` carries channel-assigned threading pointers (the delivered
  # message's id/anchor) back to the caller; bridges without receipts return `:ok`,
  # which `Zaq.Channels.Api` normalizes to `{:ok, %{}}`.
  @callback send_reply(term(), map()) :: :ok | {:ok, receipt :: map()} | {:error, term()}
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
  @callback conversation_key(Incoming.t()) :: String.t() | nil
  @callback outbound_conversation_key(String.t() | nil, String.t() | nil) :: String.t() | nil
  @callback open_dm_channel(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_mailboxes(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
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
                      conversation_key: 1,
                      outbound_conversation_key: 2

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

      defdelegate route_incoming_message(msg, pipeline_opts, actor, opts \\ []),
        to: Zaq.Channels.CommunicationBridge

      defdelegate dispatch_message_rating(message_ref, rater_attrs, opts \\ []),
        to: Zaq.Channels.CommunicationBridge
    end
  end

  @doc """
  Lists communication providers a message can be sent through.

  Delegates to `Zaq.Channels.Bridge.list_providers/2`, which owns the menu for
  every channel kind — see that function for what makes a provider eligible.
  """
  @spec list_providers() :: {:ok, map()}
  def list_providers, do: Bridge.list_providers(:communication)

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

  # ── Conversation identity ────────────────────────────────────────────
  #
  # Identity (channel type + grouping key) is computed here in the channels
  # layer and carried on the data. Engine modules consume the stamped values
  # and never derive channel identity themselves.

  @doc """
  Canonical conversation channel type for a provider.

  Conversations are grouped under one channel type per transport family:
  inbound and outbound email share `"email:imap"`, the back office web UI is
  `"bo"`, and non-provider values fall back to `"api"`.
  """
  @spec conversation_channel_type(term(), keyword()) :: String.t()
  def conversation_channel_type(provider, opts \\ [])

  def conversation_channel_type(provider, opts) when is_atom(provider) and not is_nil(provider),
    do: conversation_channel_type(Atom.to_string(provider), opts)

  def conversation_channel_type(provider, _opts) when is_binary(provider) do
    case provider do
      "email" -> "email:imap"
      "email:smtp" -> "email:imap"
      "web" -> "bo"
      other -> other
    end
  end

  def conversation_channel_type(_provider, _opts), do: "api"

  @doc """
  Conversation grouping key for an incoming message, resolved by the channel's
  bridge when it defines one.

  Dispatches to the optional `conversation_key/1` bridge callback. Returns `nil`
  when the channel has no bridge-specific grouping — callers own the generic
  fallback (typically the author id). Resolves the bridge from application
  config only; the persist path must never hit `ChannelConfig`.
  """
  @spec conversation_key(Incoming.t(), String.t(), keyword()) :: String.t() | nil
  def conversation_key(incoming, channel_type, opts \\ [])

  def conversation_key(%Incoming{} = incoming, channel_type, opts) do
    case identity_bridge(channel_type, :conversation_key, 1, opts) do
      nil -> nil
      bridge -> bridge.conversation_key(incoming)
    end
  end

  @doc """
  Conversation grouping key for an outbound-first send on `platform`, resolved
  by the platform's bridge when it defines one.

  Platforms without the callback resolve to `nil`, meaning the send carries no
  conversation-inherited threading.
  """
  @spec outbound_conversation_key(term(), String.t() | nil, String.t() | nil, keyword()) ::
          String.t() | nil
  def outbound_conversation_key(platform, topic, subject, opts \\ []) do
    case identity_bridge(platform, :outbound_conversation_key, 2, opts) do
      nil -> nil
      bridge -> bridge.outbound_conversation_key(topic, subject)
    end
  end

  @doc """
  Conversation identity for an outbound-first send on `platform`.

  Returned as a map so the engine can consume it whole over the
  `:conversation_identity` event; `conversation_key` is `nil` when the
  platform defines no outbound grouping.
  """
  @spec outbound_conversation_identity(term(), String.t() | nil, String.t() | nil, keyword()) ::
          %{channel_type: String.t(), conversation_key: String.t() | nil}
  def outbound_conversation_identity(platform, topic, subject, opts \\ []) do
    %{
      channel_type: conversation_channel_type(platform, opts),
      conversation_key: outbound_conversation_key(platform, topic, subject, opts)
    }
  end

  @doc """
  Stamps the channel-computed conversation identity onto the incoming envelope
  as `metadata["conversation"]` (`%{"channel_type" => ..., "key" => ...}`).

  Called at the channel chokepoints (`route_incoming_message/5`,
  `Bridge.persist_from_incoming/5`, the `:conversation_identity` event) so
  every message reaching engine persistence already carries its identity.
  """
  @spec put_conversation_identity(Incoming.t(), keyword()) :: Incoming.t()
  def put_conversation_identity(%Incoming{} = msg, opts \\ []) do
    channel_type = conversation_channel_type(msg.provider, opts)

    identity = %{
      "channel_type" => channel_type,
      "key" => conversation_key(msg, channel_type, opts)
    }

    %{msg | metadata: Map.put(msg.metadata || %{}, "conversation", identity)}
  end

  defp identity_bridge(provider, fun, arity, opts) do
    case Bridge.bridge_for(provider, opts) do
      nil -> nil
      bridge -> if bridge_supports?(bridge, fun, arity), do: bridge, else: nil
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
  @spec route_incoming_message(Incoming.t(), keyword(), map(), keyword()) ::
          Outgoing.t() | :ok | {:error, term()}
  def route_incoming_message(%Incoming{} = msg, pipeline_opts, actor, opts \\ [])
      when is_list(pipeline_opts) and is_map(actor) and is_list(opts) do
    node_router_module = Keyword.get(opts, :node_router, NodeRouter)
    pipeline_module = Keyword.get(opts, :pipeline_module, Zaq.Agent.Pipeline)

    msg =
      msg
      |> put_routing_context(opts)
      |> put_conversation_identity()

    route_resolved_incoming_message(
      msg,
      pipeline_opts,
      actor,
      opts,
      node_router_module,
      pipeline_module
    )
  end

  defp route_resolved_incoming_message(
         %Incoming{} = msg,
         pipeline_opts,
         actor,
         opts,
         node_router_module,
         Zaq.Agent.Pipeline
       ) do
    msg
    |> build_incoming_routing_event(pipeline_opts, actor, opts)
    |> dispatch_incoming_routing_event(node_router_module)
  end

  defp route_resolved_incoming_message(
         %Incoming{} = msg,
         pipeline_opts,
         _actor,
         _opts,
         _node_router_module,
         pipeline_module
       ) do
    pipeline_module.run(msg, pipeline_opts)
  end

  @doc "Builds the canonical Engine request for channel-originated incoming routing."
  @spec build_incoming_routing_event(Incoming.t(), keyword(), map(), keyword()) :: Event.t()
  def build_incoming_routing_event(%Incoming{} = msg, pipeline_opts, actor, opts \\ [])
      when is_list(pipeline_opts) and is_map(actor) and is_list(opts) do
    event_opts =
      [action: :route_incoming_message, pipeline_opts: pipeline_opts]
      |> maybe_put_event_opt(:identity_opts, Keyword.get(opts, :identity_opts))
      |> maybe_put_event_opt(:identity_resolver, Keyword.get(opts, :identity_resolver))
      |> maybe_put_event_opt(:node_router, Keyword.get(opts, :node_router))

    Event.new(msg, :engine,
      type: :sync,
      name: :incoming_message_routing_requested,
      opts: event_opts,
      actor: actor
    )
  end

  defp dispatch_incoming_routing_event(%Event{} = event, node_router_module) do
    case node_router_module.dispatch(event) do
      %Event{response: {:error, _} = error} -> error
      %Event{response: %Outgoing{} = outgoing} -> outgoing
      %Event{response: {:ok, %Outgoing{} = outgoing}} -> outgoing
      %Event{} -> :ok
    end
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

  @doc """
  Dispatches a channel-originated message rating to the engine.

  `rater_attrs` is the origin-agnostic payload the engine's `:rate_message`
  action takes — the same map the back-office builds. Channels are responsible
  for mapping their provider's reaction vocabulary to a ZAQ rating *before*
  calling this; the engine never learns the rating came from a reaction.

  `message_ref` is `{:id, uuid}` when the caller already holds the message's
  primary key, or `{:external_id, provider_message_id}` when it only has the
  provider's identifier.

  Returns the engine's response verbatim.
  """
  @spec dispatch_message_rating(
          {:id, String.t()} | {:external_id, String.t()},
          map(),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def dispatch_message_rating(message_ref, rater_attrs, opts \\ [])
      when is_map(rater_attrs) and is_list(opts) do
    node_router_module = Keyword.get(opts, :node_router, NodeRouter)

    %{message_ref: message_ref, rater_attrs: rater_attrs}
    |> Event.new(:engine, opts: [action: :rate_message])
    |> node_router_module.dispatch()
    |> Map.fetch!(:response)
  end

  defp dispatch_agent_pipeline_event(%Event{} = event, node_router_module) do
    case node_router_module.dispatch(event).response do
      %Outgoing{} = outgoing -> outgoing
      {:ok, %Outgoing{} = outgoing} -> outgoing
      # Delivery receipt from a sync deliver_outgoing hop — delivered, nothing to return.
      {:ok, receipt} when is_non_struct_map(receipt) -> :ok
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

  defp put_routing_context(%Incoming{} = msg, opts) do
    context =
      msg.routing_context
      |> Map.from_struct()
      |> maybe_put_routing_context(:channel_config_id, Keyword.get(opts, :channel_config_id))
      |> maybe_put_routing_context(
        :retrieval_channel_id,
        Keyword.get(opts, :retrieval_channel_id)
      )
      |> maybe_put_routing_context(:topic_id, Keyword.get(opts, :topic_id))
      |> RoutingContext.normalize()

    %{msg | routing_context: context}
  end

  defp maybe_put_routing_context(context, _key, nil), do: context
  defp maybe_put_routing_context(context, key, value), do: Map.put(context, key, value)

  defp maybe_put_event_opt(opts, _key, nil), do: opts
  defp maybe_put_event_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp bridge_supports?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end
end
