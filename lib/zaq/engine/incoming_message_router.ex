defmodule Zaq.Engine.IncomingMessageRouter do
  @moduledoc """
  Applies incoming-message routing policy to an Engine-routed `%Zaq.Event{}`.

  Channels dispatch unresolved incoming messages to Engine. This module enriches
  the incoming person identity when possible, resolves the matching routing rule,
  and returns the same event with executable routing fields for `NodeRouter`.
  """

  alias Zaq.Channels.EventNames
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.EventHop
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Identity.ExecutionActor
  alias Zaq.NodeRouter
  alias Zaq.People.IdentityResolver

  @doc "Routes an incoming-message event to its resolved destination."
  @spec route(Event.t()) :: Event.t()
  def route(%Event{request: %Incoming{} = incoming} = event) do
    actor = preserve_invalid_person(event.actor, incoming.person)
    {incoming, person_resolved?} = resolve_person(incoming, event.opts)
    resolution = IncomingMessageRouting.resolve(incoming, event.opts)

    event
    |> Map.put(:request, incoming)
    |> Map.put(:actor, execution_actor(actor, incoming))
    |> apply_resolution(resolution, person_resolved?)
  end

  def route(%Event{} = event),
    do: %{event | response: {:error, {:invalid_request, event.request}}}

  defp preserve_invalid_person(actor, nil), do: actor

  defp preserve_invalid_person(actor, person) do
    case ExecutionActor.validate(%{person: person}) do
      {:ok, _} -> actor
      {:error, _} -> %{person: nil}
    end
  end

  # This is the trusted ingress boundary: transport fields have already been
  # stamped by Channels/BO and Person resolution has completed. Never derive an
  # anonymous or system identity from absent transport identity.
  defp execution_actor(actor, _incoming) when not is_map(actor) and not is_nil(actor), do: actor

  defp execution_actor(actor, incoming) do
    if explicit_identity?(actor) and
         match?({:error, _}, ExecutionActor.validate(actor)) do
      actor
    else
      finalize_execution_actor(actor, incoming)
    end
  end

  defp finalize_execution_actor(actor, incoming) do
    normalized = ActorNormalizer.from_incoming(actor, incoming)

    cond do
      not is_nil(ActorNormalizer.person(normalized)) ->
        promote_origin_actor(normalized, actor)

      explicit_identity?(actor) ->
        actor

      is_binary(incoming.author_id) ->
        channel_actor(normalized, incoming)

      true ->
        normalized
    end
  end

  defp channel_actor(actor, incoming) do
    if String.trim(incoming.author_id) == "" do
      actor
    else
      Map.merge(actor || %{}, %{
        kind: :channel_subject,
        subject:
          Jason.encode!([
            to_string(incoming.provider),
            incoming.routing_context.channel_config_id,
            incoming.author_id
          ])
      })
    end
  end

  # A BO origin may acquire a Person here. Do not erase a conflicting declaration
  # already supplied alongside a Person; strict execution validation must see it.
  defp promote_origin_actor(normalized, actor) do
    if is_map(actor) and not Map.has_key?(actor, :person) and not Map.has_key?(actor, "person") and
         (Map.get(actor, :kind) || Map.get(actor, "kind")) in [
           :bo_user,
           "bo_user",
           :channel_subject,
           "channel_subject"
         ] do
      Map.drop(normalized, [:kind, "kind", :subject, "subject"])
    else
      normalized
    end
  end

  defp explicit_identity?(actor) when is_map(actor) do
    Enum.any?(
      [:person, "person", :person_id, "person_id", :kind, "kind", :subject, "subject"],
      &Map.has_key?(actor, &1)
    )
  end

  defp explicit_identity?(_), do: false

  defp resolve_person(%Incoming{} = incoming, opts) do
    resolver = Keyword.get(opts, :identity_resolver, IdentityResolver)
    resolver_opts = Keyword.get(opts, :identity_opts, [])

    case resolver.resolve(incoming, resolver_opts) do
      {:ok, person} -> {%{incoming | person: resolver.person_payload(person)}, true}
      {:error, _reason} -> {incoming, false}
    end
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
