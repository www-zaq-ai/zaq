defmodule Zaq.Engine.IncomingMessageRouter do
  @moduledoc """
  Applies incoming-message routing policy to an Engine-routed `%Zaq.Event{}`.

  Channels dispatch unresolved incoming messages to Engine. This module enriches
  the incoming person identity when possible, resolves the matching routing rule,
  and returns the same event with executable routing fields for `NodeRouter`.
  """

  alias Zaq.Channels.EventNames
  alias Zaq.Engine.IncomingAttachments
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.EventHop
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.NodeRouter
  alias Zaq.People.IdentityResolver

  @doc "Routes an incoming-message event to its resolved destination."
  @spec route(Event.t()) :: Event.t()
  def route(%Event{request: %Incoming{} = incoming} = event) do
    {incoming, person_resolved?} = resolve_person(incoming, event.opts)
    incoming = store_attachments(incoming, event.opts)
    resolution = IncomingMessageRouting.resolve(incoming, event.opts)

    event
    |> Map.put(:request, incoming)
    |> Map.put(:actor, ActorNormalizer.from_incoming(event.actor, incoming))
    |> apply_resolution(resolution, person_resolved?)
  end

  def route(%Event{} = event),
    do: %{event | response: {:error, {:invalid_request, event.request}}}

  defp resolve_person(%Incoming{} = incoming, opts) do
    resolver = Keyword.get(opts, :identity_resolver, IdentityResolver)
    resolver_opts = Keyword.get(opts, :identity_opts, [])

    case resolver.resolve(incoming, resolver_opts) do
      {:ok, person} -> {%{incoming | person: resolver.person_payload(person)}, true}
      {:error, _reason} -> {incoming, false}
    end
  end

  # Runs after person resolution because the storage path is built from the resolved
  # identity, and before routing so both the agent and workflow-only paths see the same
  # message.
  defp store_attachments(%Incoming{} = incoming, opts) do
    attachments_module = Keyword.get(opts, :attachments_module, IncomingAttachments)
    attachments_module.store(incoming, node_router: Keyword.get(opts, :node_router, NodeRouter))
  end

  defp apply_resolution(%Event{} = event, %{mode: :agent} = resolution, person_resolved?) do
    configured_agent_id = resolution.configured_agent_id
    agent_hop_type = Keyword.get(event.opts, :agent_hop_type, :async)

    event
    |> Map.put(:next_hop, EventHop.new(:agent, agent_hop_type, DateTime.utc_now()))
    |> Map.put(:name, EventNames.message_received(event.request, :agent_requested))
    |> Map.put(:opts,
      action: :run_pipeline,
      pipeline_opts: Keyword.get(event.opts, :pipeline_opts, [])
    )
    |> put_routing_assign(resolution, person_resolved?)
    |> maybe_put_agent_selection(configured_agent_id, resolution.source)
  end

  defp apply_resolution(%Event{} = event, %{mode: :none} = resolution, person_resolved?) do
    event
    |> Map.put(:next_hop, nil)
    |> Map.put(:name, EventNames.message_received(event.request, :workflow_only))
    |> put_routing_assign(resolution, person_resolved?)
    |> fire_terminal_event()
  end

  defp fire_terminal_event(%Event{} = event) do
    event.opts
    |> Keyword.get(:node_router, NodeRouter)
    |> then(& &1.fire(event))
  end

  defp put_routing_assign(%Event{} = event, resolution, person_resolved?) do
    context = event.request.routing_context
    rule = resolution.rule

    routing = %{
      "mode" => Atom.to_string(resolution.mode),
      "source" => Atom.to_string(resolution.source),
      "rule_id" => rule && rule.id,
      "configured_agent_id" => resolution.configured_agent_id,
      "person_resolved" => person_resolved?,
      "channel_config_id" => context.channel_config_id,
      "retrieval_channel_id" => context.retrieval_channel_id,
      "topic_id" => context.topic_id,
      "provider" => to_string(event.request.provider)
    }

    %{event | assigns: Map.put(event.assigns || %{}, "incoming_message_routing", routing)}
  end

  defp maybe_put_agent_selection(%Event{} = event, nil, _source), do: event

  defp maybe_put_agent_selection(%Event{} = event, configured_agent_id, source) do
    selection = %{"agent_id" => configured_agent_id, "source" => Atom.to_string(source)}
    %{event | assigns: Map.put(event.assigns || %{}, "agent_selection", selection)}
  end
end
