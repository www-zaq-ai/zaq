defmodule Zaq.Engine.IncomingMessageRouting do
  @moduledoc """
  Context for incoming-message routing rules and resolution.

  This module is the single source of truth for incoming-message routing policy.
  Channel bridges may provide routing facts, but they must not resolve the final
  destination outside this context.

  Clearing a scoped rule preserves inheritance. If no eligible configured agent
  or explicit rule matches, routing resolves to `:none` (workflow-only).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Zaq.Agent
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.MapUtils
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils

  @type source ::
          :incoming
          | :topic
          | :channel
          | :provider
          | :global
          | :person_topic
          | :person_channel
          | :person_provider
          | :person_global
          | :no_matching_rule
  @scope_keys [:person_id, :channel_config_id, :retrieval_channel_id, :topic_id]

  @doc "Lists persisted Person overrides for administrative presentation."
  @spec list_person_rules(pos_integer()) :: [IncomingMessageRoutingRule.t()]
  def list_person_rules(person_id) do
    Repo.all(from(r in IncomingMessageRoutingRule, where: r.person_id == ^person_id))
  end

  @doc """
  Returns a read-only changeset including current database-backed agent eligibility
  and channel ownership validation. Persistence rechecks these policies inside its
  transaction; database constraints remain authoritative for uniqueness.
  """
  def change_rule(%IncomingMessageRoutingRule{} = rule, attrs \\ %{}) do
    rule
    |> IncomingMessageRoutingRule.changeset(attrs)
    |> IncomingMessageRoutingRule.validate_policy(Repo)
  end

  @doc """
  Creates or updates a rule struct, preserving loaded identity, or the rule at a scope.
  `on_conflict: :nothing` attempts a fresh insert without reading or updating an
  existing rule. A conflict returns a rule with nil ID, as in `Repo.insert/2`.
  The default `:update` policy preserves administrative upsert behavior.
  """
  def upsert_rule(rule_or_scope, attrs, opts \\ [])

  def upsert_rule(%IncomingMessageRoutingRule{} = rule, attrs, opts) do
    policy = Keyword.get(opts, :on_conflict, :update)

    rule =
      if policy == :nothing do
        fields = Map.take(rule, @scope_keys ++ [:routing_mode, :configured_agent_id])

        IncomingMessageRoutingRule
        |> struct(fields)
        |> Ecto.put_meta(prefix: Ecto.get_meta(rule, :prefix))
      else
        rule
      end

    changeset = change_rule(rule, attrs)

    case policy do
      :update -> Repo.insert_or_update(changeset)
      :nothing -> Repo.insert(changeset, on_conflict: :nothing, returning: true)
      other -> {:error, {:invalid_conflict_policy, other}}
    end
  end

  def upsert_rule(scope_attrs, route_attrs, opts)
      when is_map(scope_attrs) and is_map(route_attrs) do
    rule =
      case Keyword.get(opts, :on_conflict, :update) do
        :nothing -> %IncomingMessageRoutingRule{}
        _ -> get_rule(scope_attrs) || %IncomingMessageRoutingRule{}
      end

    upsert_rule(rule, Map.merge(scope_attrs, route_attrs), opts)
  end

  @doc "Deletes the rule at the given scope, returning `{:ok, nil}` when absent."
  def delete_rule(scope_attrs) when is_map(scope_attrs) do
    case get_rule(scope_attrs) do
      nil -> {:ok, nil}
      %IncomingMessageRoutingRule{} = rule -> Repo.delete(rule)
    end
  end

  @doc """
  Applies routing commands in order. `write_mode: "insert_if_absent"` inserts
  without updating a concurrent winner; omitted/`"upsert"` keeps normal writes.
  Insert-only clear commands are invalid. Existing rules return a `"noop"` result.
  """
  def apply_rule_commands(rules, opts \\ [])

  def apply_rule_commands(rules, opts) when is_list(rules) do
    rules
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      case apply_rule_command(rule, opts) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} ->
        results = Enum.reverse(results)
        {:ok, %{results: results, count: length(results)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_rule_commands(_rules, _opts), do: {:error, "rules must be a list"}

  defp apply_rule_command(rule, opts) when is_map(rule) do
    with {:ok, scope} <- command_scope_attrs(rule),
         {:ok, mode} <- command_routing_mode(rule),
         {:ok, write_mode} <- command_write_mode(rule, mode) do
      case write_mode do
        :upsert ->
          persist_rule_command(scope, mode, rule, opts)

        :insert_if_absent ->
          persist_rule_command(scope, mode, rule, Keyword.put(opts, :on_conflict, :nothing))
      end
    end
  end

  defp apply_rule_command(_rule, _opts), do: {:error, "each rule must be a map"}

  defp command_write_mode(rule, mode) do
    case MapUtils.fetch(rule, :write_mode) do
      value when value in [nil, :upsert, "upsert"] ->
        {:ok, :upsert}

      value when value in [:insert_if_absent, "insert_if_absent"] and mode != :clear ->
        {:ok, :insert_if_absent}

      value ->
        {:error, "invalid write_mode #{inspect(value)} for #{mode} routing"}
    end
  end

  defp command_scope_attrs(rule) do
    scope =
      @scope_keys
      |> Enum.reduce(%{}, fn key, acc ->
        value = MapUtils.fetch(rule, key)

        case normalize_command_scope_value(key, value) do
          nil -> acc
          normalized -> Map.put(acc, key, normalized)
        end
      end)

    if Map.has_key?(scope, :topic_id) and not Map.has_key?(scope, :channel_config_id) do
      {:error, "channel_config_id is required for topic rules"}
    else
      {:ok, scope}
    end
  end

  defp normalize_command_scope_value(:topic_id, value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      topic -> topic
    end
  end

  defp normalize_command_scope_value(:topic_id, _value), do: nil
  defp normalize_command_scope_value(_key, value), do: ParseUtils.parse_optional_int(value)

  defp command_routing_mode(rule) do
    case MapUtils.fetch(rule, :routing_mode) || MapUtils.fetch(rule, :mode) do
      mode when mode in [:agent, "agent"] -> {:ok, :agent}
      mode when mode in [:none, "none"] -> {:ok, :none}
      mode when mode in [:default, "default", :clear, "clear", nil, ""] -> {:ok, :clear}
      other -> {:error, "invalid routing_mode #{inspect(other)}"}
    end
  end

  defp persist_rule_command(scope, :clear, _rule, opts) do
    case delete_rule(scope) do
      {:ok, nil} ->
        {:ok, %{status: "noop", rule: nil}}

      {:ok, %IncomingMessageRoutingRule{} = rule} ->
        {:ok, %{status: "deleted", rule: rule_payload(rule)}}

      {:error, reason} ->
        {:error, format_command_error(reason, opts)}
    end
  end

  defp persist_rule_command(scope, :none, _rule, opts) do
    persist_route(scope, %{routing_mode: :none}, opts)
  end

  defp persist_rule_command(scope, :agent, rule, opts) do
    case ParseUtils.parse_optional_int(MapUtils.fetch(rule, :configured_agent_id)) do
      nil ->
        {:error, "configured_agent_id is required for agent routing"}

      configured_agent_id ->
        persist_route(
          scope,
          %{routing_mode: :agent, configured_agent_id: configured_agent_id},
          opts
        )
    end
  end

  defp persist_route(scope, attrs, opts) do
    policy = Keyword.get(opts, :on_conflict, :update)

    case upsert_rule(scope, attrs, on_conflict: policy) do
      {:ok, %IncomingMessageRoutingRule{id: nil}} ->
        case get_rule(scope) do
          nil -> {:error, :routing_conflict_retry}
          existing -> {:ok, %{status: "noop", rule: rule_payload(existing)}}
        end

      {:ok, %IncomingMessageRoutingRule{} = rule} ->
        status = if policy == :nothing, do: "inserted", else: "upserted"
        {:ok, %{status: status, rule: rule_payload(rule)}}

      {:error, reason} ->
        {:error, format_command_error(reason, opts)}
    end
  end

  defp rule_payload(%IncomingMessageRoutingRule{} = rule) do
    %{
      id: rule.id,
      person_id: rule.person_id,
      channel_config_id: rule.channel_config_id,
      retrieval_channel_id: rule.retrieval_channel_id,
      topic_id: rule.topic_id,
      routing_mode: to_string(rule.routing_mode),
      configured_agent_id: rule.configured_agent_id
    }
  end

  defp format_command_error(reason, opts) do
    if Keyword.get(opts, :raw_errors, false) do
      reason
    else
      json_safe_error(reason)
    end
  end

  defp json_safe_error(%Changeset{} = changeset),
    do: Changeset.traverse_errors(changeset, &translate_error/1)

  defp json_safe_error(reason), do: inspect(reason)

  defp translate_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp translate_error(message) when is_binary(message), do: message

  @doc "Fetches the rule at an exact scope."
  def get_rule(scope_attrs) when is_map(scope_attrs) do
    IncomingMessageRoutingRule
    |> exact_scope_query(scope_attrs)
    |> Repo.one()
  end

  @doc "Resolves the most specific valid rule for an incoming message."
  def resolve(%Incoming{} = incoming, opts \\ []) do
    agent_module = Keyword.get(opts, :agent_module, Agent)

    case transient_resolution(incoming, agent_module) do
      {:ok, resolution} ->
        resolution

      :none ->
        persisted_rule_resolution(incoming, agent_module)
    end
  end

  defp persisted_rule_resolution(%Incoming{} = incoming, agent_module) do
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

  defp transient_resolution(%Incoming{} = incoming, agent_module) do
    incoming.routing_context.attributes
    |> transient_configured_agent_id()
    |> case do
      nil ->
        :none

      configured_agent_id ->
        case agent_module.get_conversation_enabled_agent(configured_agent_id) do
          {:ok, _agent} ->
            {:ok,
             %{
               mode: :agent,
               source: :incoming,
               rule: nil,
               configured_agent_id: configured_agent_id
             }}

          {:error, _reason} ->
            :none
        end
    end
  end

  defp transient_configured_agent_id(attributes) when is_map(attributes) do
    attributes
    |> Map.get("configured_agent_id")
    |> case do
      id when is_integer(id) and id > 0 -> id
      id when is_binary(id) -> parse_positive_int(id)
      _ -> nil
    end
  end

  defp transient_configured_agent_id(_attributes), do: nil

  defp parse_positive_int(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
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

  defp source(%IncomingMessageRoutingRule{retrieval_channel_id: id, person_id: person_id})
       when not is_nil(id),
       do: scoped_source(person_id, :channel)

  defp source(%IncomingMessageRoutingRule{topic_id: id, person_id: person_id})
       when not is_nil(id),
       do: scoped_source(person_id, :topic)

  defp source(%IncomingMessageRoutingRule{channel_config_id: id, person_id: person_id})
       when not is_nil(id),
       do: scoped_source(person_id, :provider)

  defp source(%IncomingMessageRoutingRule{person_id: person_id}),
    do: scoped_source(person_id, :global)

  defp scoped_source(nil, source), do: source
  defp scoped_source(_person_id, :channel), do: :person_channel
  defp scoped_source(_person_id, :topic), do: :person_topic
  defp scoped_source(_person_id, :provider), do: :person_provider
  defp scoped_source(_person_id, :global), do: :person_global

  defp default_resolution do
    %{mode: :none, source: :no_matching_rule, rule: nil, configured_agent_id: nil}
  end

  defp scope_keys, do: @scope_keys
end
