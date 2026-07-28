defmodule Zaq.Engine.IncomingMessageRouting do
  @moduledoc """
  Context for incoming-message routing rules and resolution.

  This module is the single source of truth for incoming-message routing policy.
  Channel bridges may provide routing facts, but they must not resolve the final
  destination outside this context.
  """

  import Ecto.Query

  alias Zaq.Agent
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Repo

  @type source :: :topic | :channel | :provider | :global | :default_zaq_agent

  @doc "Returns a changeset for an incoming-message routing rule."
  def change_rule(%IncomingMessageRoutingRule{} = rule, attrs \\ %{}) do
    IncomingMessageRoutingRule.changeset(rule, attrs)
  end

  @doc "Creates or updates the rule for a scope."
  def upsert_rule(scope_attrs, route_attrs) when is_map(scope_attrs) and is_map(route_attrs) do
    attrs = Map.merge(scope_attrs, route_attrs)

    case get_rule(scope_attrs) do
      nil -> %IncomingMessageRoutingRule{}
      %IncomingMessageRoutingRule{} = rule -> rule
    end
    |> IncomingMessageRoutingRule.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Deletes the rule at the given scope, returning `{:ok, nil}` when absent."
  def delete_rule(scope_attrs) when is_map(scope_attrs) do
    case get_rule(scope_attrs) do
      nil -> {:ok, nil}
      %IncomingMessageRoutingRule{} = rule -> Repo.delete(rule)
    end
  end

  @doc "Fetches the rule at an exact scope."
  def get_rule(scope_attrs) when is_map(scope_attrs) do
    IncomingMessageRoutingRule
    |> exact_scope_query(scope_attrs)
    |> Repo.one()
  end

  @doc "Resolves the most specific valid rule for an incoming message."
  def resolve(%Incoming{} = incoming, opts \\ []) do
    agent_module = Keyword.get(opts, :agent_module, Agent)

    incoming
    |> candidate_rules_query()
    |> Repo.all()
    |> sort_candidates(incoming)
    |> Enum.reduce_while(default_resolution(), fn rule, _fallback ->
      case rule_resolution(rule, agent_module) do
        {:skip, _reason} -> {:cont, default_resolution()}
        resolution -> {:halt, resolution}
      end
    end)
  end

  defp exact_scope_query(query, scope_attrs) do
    Enum.reduce(scope_keys(), query, fn key, query ->
      value = Map.get(scope_attrs, key) || Map.get(scope_attrs, Atom.to_string(key))

      case value do
        nil -> where(query, [r], is_nil(field(r, ^key)))
        value -> where(query, [r], field(r, ^key) == ^value)
      end
    end)
  end

  defp candidate_rules_query(%Incoming{} = incoming) do
    person_id = Incoming.person_id(incoming)
    context = incoming.routing_context

    IncomingMessageRoutingRule
    |> maybe_person_query(person_id)
    |> maybe_scope_query(:channel_config_id, context.channel_config_id)
    |> maybe_scope_query(:retrieval_channel_id, context.retrieval_channel_id)
    |> maybe_scope_query(:topic_id, context.topic_id)
  end

  defp maybe_person_query(query, nil), do: where(query, [r], is_nil(r.person_id))

  defp maybe_person_query(query, person_id),
    do: where(query, [r], is_nil(r.person_id) or r.person_id == ^person_id)

  defp maybe_scope_query(query, field, nil), do: where(query, [r], is_nil(field(r, ^field)))

  defp maybe_scope_query(query, field, value),
    do: where(query, [r], is_nil(field(r, ^field)) or field(r, ^field) == ^value)

  defp sort_candidates(rules, %Incoming{} = incoming) do
    Enum.sort_by(rules, &precedence(&1, incoming))
  end

  defp precedence(%IncomingMessageRoutingRule{person_id: person_id} = rule, _incoming) do
    person_offset = if person_id, do: 0, else: 10

    person_offset +
      cond do
        rule.retrieval_channel_id -> 1
        rule.topic_id -> 2
        rule.channel_config_id -> 3
        true -> 4
      end
  end

  defp rule_resolution(%IncomingMessageRoutingRule{routing_mode: :none} = rule, _agent_module) do
    %{mode: :none, source: source(rule), rule: rule, configured_agent_id: nil}
  end

  defp rule_resolution(%IncomingMessageRoutingRule{routing_mode: :agent} = rule, agent_module) do
    case agent_module.get_conversation_enabled_agent(rule.configured_agent_id) do
      {:ok, _agent} ->
        %{
          mode: :agent,
          source: source(rule),
          rule: rule,
          configured_agent_id: rule.configured_agent_id
        }

      {:error, reason} ->
        {:skip, reason}
    end
  end

  defp source(%IncomingMessageRoutingRule{retrieval_channel_id: id}) when not is_nil(id),
    do: :channel

  defp source(%IncomingMessageRoutingRule{topic_id: id}) when not is_nil(id), do: :topic

  defp source(%IncomingMessageRoutingRule{channel_config_id: id}) when not is_nil(id),
    do: :provider

  defp source(_rule), do: :global

  defp default_resolution do
    %{mode: :agent, source: :default_zaq_agent, rule: nil, configured_agent_id: nil}
  end

  defp scope_keys, do: [:person_id, :channel_config_id, :retrieval_channel_id, :topic_id]
end
