defmodule ZaqWeb.Live.BO.System.PersonRouting do
  @moduledoc "Presentation helpers for connector-scoped People routing administration."

  alias Zaq.Accounts.{Person, PersonChannel}
  alias Zaq.Channels.{AgentRouting, RetrievalChannel}
  alias Zaq.Engine.ChannelConfig
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions
  alias ZaqWeb.Live.BO.EngineDispatch

  def maybe_persist_person_global_rule(%Person{id: person_id}, %{"routing_agent_id" => raw_id}) do
    EngineDispatch.dispatch(:people_command, %{
      op: :set_person_routing_agent,
      params: %{person_id: person_id, choice: raw_id}
    })
  end

  def maybe_persist_person_global_rule(_, _), do: {:ok, :skipped}

  def person_global_agent_value(nil), do: ""
  def person_global_agent_value(%Person{id: id}), do: rule_value(%{person_id: id})

  def person_provider_agent_value(nil, _), do: ""

  def person_provider_agent_value(%Person{id: id}, %ChannelConfig{id: config_id}),
    do: rule_value(%{person_id: id, channel_config_id: config_id})

  def person_retrieval_agent_value(nil, _), do: ""

  def person_retrieval_agent_value(%Person{id: id}, %RetrievalChannel{} = channel),
    do:
      rule_value(%{
        person_id: id,
        channel_config_id: channel.channel_config_id,
        retrieval_channel_id: channel.id
      })

  def person_topic_agent_value(nil, _, _), do: ""

  def person_topic_agent_value(%Person{id: id}, %ChannelConfig{id: config_id}, topic),
    do: rule_value(%{person_id: id, channel_config_id: config_id, topic_id: topic})

  def routing_choice_label("", _), do: "Default"

  def routing_choice_label(value, options) do
    if value == AgentRouting.none_value(),
      do: "NONE",
      else: routing_agent_label(value, options)
  end

  defp routing_agent_label(value, options) do
    Enum.find_value(options, "Agent #{value}", fn {label, option} ->
      if to_string(option) == to_string(value), do: label
    end)
  end

  def routing_select_options(options), do: [{"Default", ""} | options]

  @doc "Loads the management catalog once; validation filters this assigned data only."
  def routing_targets do
    case EngineDispatch.dispatch(:people_command, %{op: :channel_routing_targets, params: %{}}) do
      {:ok, targets} -> targets
      _ -> []
    end
  end

  def person_channel_routing_configs(channel, targets \\ [])

  def person_channel_routing_configs(
        %PersonChannel{platform: platform, channel_config_id: id},
        targets
      ),
      do: Enum.filter(targets, &(&1.platform == platform and &1.config.id == id and &1.incoming?))

  def person_channel_routing_configs(_, _), do: []

  def routing_configs_for_platform(platform, targets),
    do: Enum.filter(targets, &(&1.platform == platform))

  def routing_values(%Person{id: id}) when is_integer(id) do
    case EngineDispatch.dispatch(:people_command, %{
           op: :person_routing_rules,
           params: %{person_id: id}
         }) do
      {:ok, rules} ->
        Map.new(rules, &rule_entry/1)

      _ ->
        %{}
    end
  end

  def routing_values(_), do: %{}

  defp rule_entry(rule) do
    {{rule.channel_config_id, rule.retrieval_channel_id, rule.topic_id},
     AgentRouting.rule_select_value(rule)}
  end

  def cached_value(values, config_id \\ nil, retrieval_id \\ nil, topic_id \\ nil),
    do: Map.get(values, {config_id, retrieval_id, topic_id}, "")

  def form_value(params, values, config_id, retrieval_id \\ nil, topic_id \\ nil) do
    key =
      AgentRoutingOptions.rule_key(%{
        channel_config_id: config_id,
        retrieval_channel_id: retrieval_id,
        topic_id: topic_id
      })

    get_in(params || %{}, ["rules", key, "choice"]) ||
      cached_value(values, config_id, retrieval_id, topic_id)
  end

  defp rule_value(scope), do: AgentRoutingOptions.scope_rule_value(scope)
end
