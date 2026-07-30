defmodule ZaqWeb.Live.BO.System.PersonRouting do
  @moduledoc """
  Person-scoped incoming message routing helpers for the BO People UI.

  This module keeps routing rule construction, display values, and routing
  config lookup out of `PeopleLive` so the LiveView can focus on socket state
  and modal flow.
  """

  alias Zaq.Accounts.{Person, PersonChannel}
  alias Zaq.Channels.{AgentRouting, ChannelConfig, RetrievalChannel}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.Utils.ParseUtils

  @doc "Persists the selected person-global routing rule when present."
  def maybe_persist_person_global_rule(%Person{id: person_id}, %{"routing_agent_id" => raw_id}) do
    with {:ok, choice} <- AgentRouting.validate_choice(raw_id) do
      %{person_id: person_id}
      |> AgentRouting.rule_attrs(choice)
      |> then(&dispatch_routing_rules([&1]))
    end
  end

  def maybe_persist_person_global_rule(_person, _attrs), do: {:ok, :skipped}

  @doc "Persists provider, retrieval-channel, and topic routing rules from channel form attrs."
  def maybe_persist_channel_routing_rules(person_id, attrs) do
    attrs
    |> channel_routing_rules(person_id)
    |> case do
      {:ok, []} -> {:ok, :skipped}
      {:ok, rules} -> dispatch_routing_rules(rules)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the select value for the person-global routing rule."
  def person_global_agent_value(nil), do: ""

  def person_global_agent_value(%Person{id: person_id}) do
    %{person_id: person_id}
    |> IncomingMessageRouting.get_rule()
    |> routing_rule_select_value()
  end

  @doc "Returns the select value for a person-provider routing rule."
  def person_provider_agent_value(nil, _config), do: ""

  def person_provider_agent_value(%Person{id: person_id}, %ChannelConfig{} = config) do
    %{person_id: person_id, channel_config_id: config.id}
    |> IncomingMessageRouting.get_rule()
    |> routing_rule_select_value()
  end

  @doc "Returns the select value for a person retrieval-channel routing rule."
  def person_retrieval_agent_value(nil, _retrieval_channel), do: ""

  def person_retrieval_agent_value(
        %Person{id: person_id},
        %RetrievalChannel{} = retrieval_channel
      ) do
    %{
      person_id: person_id,
      channel_config_id: retrieval_channel.channel_config_id,
      retrieval_channel_id: retrieval_channel.id
    }
    |> IncomingMessageRouting.get_rule()
    |> routing_rule_select_value()
  end

  @doc "Returns the select value for a person topic/mailbox routing rule."
  def person_topic_agent_value(nil, _config, _mailbox), do: ""

  def person_topic_agent_value(%Person{id: person_id}, %ChannelConfig{} = config, mailbox) do
    %{person_id: person_id, channel_config_id: config.id, topic_id: mailbox}
    |> IncomingMessageRouting.get_rule()
    |> routing_rule_select_value()
  end

  @doc "Human label for a routing choice select value."
  def routing_choice_label("", _agent_options), do: "Default"

  def routing_choice_label(value, agent_options) do
    if value == AgentRouting.none_value(),
      do: "NONE",
      else: routing_agent_label(value, agent_options)
  end

  @doc "Select options for a routing choice, including the inherited default option."
  def routing_select_options(agent_options), do: [{"Default", ""} | agent_options]

  @doc "Incoming routing configs available for a person channel platform."
  def person_channel_routing_configs(%PersonChannel{platform: platform}) do
    routing_configs_for_platform(platform)
  end

  def person_channel_routing_configs(_channel), do: []

  @doc "Incoming routing configs available for a platform."
  def routing_configs_for_platform(platform) do
    platform
    |> ChannelConfig.list_incoming_routing_configs_for_platform()
    |> Enum.map(fn config ->
      %{
        config: config,
        retrieval_channels: RetrievalChannel.list_by_config(config.id),
        mailboxes: mailbox_routing_targets(config)
      }
    end)
  end

  defp channel_routing_rules(attrs, person_id) do
    with {:ok, provider_rules} <- provider_routing_rules(attrs, person_id),
         {:ok, retrieval_rules} <- retrieval_routing_rules(attrs, person_id),
         {:ok, topic_rules} <- topic_routing_rules(attrs, person_id) do
      {:ok, provider_rules ++ retrieval_rules ++ topic_rules}
    end
  end

  defp provider_routing_rules(%{"provider_agent_ids" => agent_ids}, person_id)
       when is_map(agent_ids) do
    reduce_choice_map(agent_ids, fn config_id, choice ->
      with {:ok, id} <- ParseUtils.parse_int_strict(config_id) do
        {:ok, AgentRouting.rule_attrs(%{person_id: person_id, channel_config_id: id}, choice)}
      end
    end)
  end

  defp provider_routing_rules(_attrs, _person_id), do: {:ok, []}

  defp retrieval_routing_rules(%{"retrieval_agent_ids" => agent_ids}, person_id)
       when is_map(agent_ids) do
    reduce_choice_map(agent_ids, fn retrieval_channel_id, choice ->
      with {:ok, id} <- ParseUtils.parse_int_strict(retrieval_channel_id),
           %RetrievalChannel{} = retrieval_channel <- Repo.get(RetrievalChannel, id) do
        {:ok,
         AgentRouting.rule_attrs(
           %{
             person_id: person_id,
             channel_config_id: retrieval_channel.channel_config_id,
             retrieval_channel_id: retrieval_channel.id
           },
           choice
         )}
      else
        _ -> {:error, :invalid_retrieval_channel}
      end
    end)
  end

  defp retrieval_routing_rules(_attrs, _person_id), do: {:ok, []}

  defp topic_routing_rules(%{"topic_agent_ids" => agent_ids}, person_id) when is_map(agent_ids) do
    agent_ids
    |> Enum.reduce_while({:ok, []}, fn {config_id, mailbox_choices}, {:ok, acc} ->
      with {:ok, id} <- ParseUtils.parse_int_strict(config_id),
           true <- is_map(mailbox_choices),
           {:ok, rules} <- topic_config_routing_rules(id, mailbox_choices, person_id) do
        {:cont, {:ok, acc ++ rules}}
      else
        _ -> {:halt, {:error, :invalid_topic_rule}}
      end
    end)
  end

  defp topic_routing_rules(_attrs, _person_id), do: {:ok, []}

  defp topic_config_routing_rules(config_id, mailbox_choices, person_id) do
    reduce_choice_map(mailbox_choices, fn mailbox, choice ->
      {:ok,
       AgentRouting.rule_attrs(
         %{person_id: person_id, channel_config_id: config_id, topic_id: mailbox},
         choice
       )}
    end)
  end

  defp reduce_choice_map(choice_map, build_rule) do
    Enum.reduce_while(choice_map, {:ok, []}, fn {key, raw_id}, {:ok, acc} ->
      with {:ok, choice} <- AgentRouting.validate_choice(raw_id),
           {:ok, rule} <- build_rule.(key, choice) do
        {:cont, {:ok, [rule | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_routing_choice}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  defp dispatch_routing_rules(rules) do
    %{rules: rules, raw_errors: true}
    |> Event.new(:engine, opts: [action: :upsert_incoming_message_routing_rules])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp routing_rule_select_value(%{routing_mode: :none}), do: AgentRouting.none_value()

  defp routing_rule_select_value(%{
         routing_mode: :agent,
         configured_agent_id: configured_agent_id
       }),
       do: AgentRouting.select_value(configured_agent_id)

  defp routing_rule_select_value(_rule), do: ""

  defp routing_agent_label(value, agent_options) do
    Enum.find_value(agent_options, "Agent #{value}", fn {label, option_value} ->
      if to_string(option_value) == to_string(value), do: label
    end)
  end

  defp mailbox_routing_targets(%ChannelConfig{provider: "email:imap"} = config),
    do: ChannelConfig.imap_selected_mailboxes(config)

  defp mailbox_routing_targets(_config), do: []
end
