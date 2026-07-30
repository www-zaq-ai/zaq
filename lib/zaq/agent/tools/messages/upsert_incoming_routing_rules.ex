defmodule Zaq.Agent.Tools.Messages.UpsertIncomingRoutingRules do
  @moduledoc """
  Creates, updates, or clears incoming-message routing rules.

  This is the standard tool command for `Zaq.Engine.IncomingMessageRoutingRule`.
  It dispatches to the Engine node so BO screens, workflows, and configured agents
  use the same validation and persistence path.

  Example:

      %{rules: [%{channel_config_id: 12, topic_id: "INBOX", routing_mode: "agent", configured_agent_id: 34}]}

  Use `routing_mode: "none"` to disable routing at a scope and `"clear"` to delete
  a rule. `"agent"` requires `configured_agent_id`.
  """

  @routing_modes ["agent", "none", "clear"]

  @incoming_rule_schema Zoi.object(%{
                          person_id:
                            Zoi.integer(
                              description: "Optional person id for person-scoped routing."
                            )
                            |> Zoi.optional(),
                          channel_config_id:
                            Zoi.integer(description: "Optional receiving channel config id.")
                            |> Zoi.optional(),
                          retrieval_channel_id:
                            Zoi.integer(
                              description:
                                "Optional retrieval channel id; requires channel_config_id."
                            )
                            |> Zoi.optional(),
                          topic_id:
                            Zoi.string(
                              description:
                                "Optional topic id, such as an IMAP mailbox; requires channel_config_id."
                            )
                            |> Zoi.optional(),
                          routing_mode:
                            Zoi.enum(@routing_modes,
                              description:
                                "Routing mode: agent, none, or clear. Agent mode requires configured_agent_id."
                            ),
                          configured_agent_id:
                            Zoi.integer(
                              description:
                                "Conversation-enabled configured agent id for agent routing."
                            )
                            |> Zoi.optional()
                        })
                        |> Zoi.refine({__MODULE__, :validate_rule, []})

  @schema Zoi.object(%{
            rules:
              Zoi.list(@incoming_rule_schema,
                description: "Incoming-message routing rule commands to apply in order."
              )
          })

  @persisted_rule_output_schema Zoi.object(%{
                                  id: Zoi.integer(description: "Persisted routing rule id."),
                                  person_id:
                                    Zoi.integer(description: "Person id for person-scoped rules.")
                                    |> Zoi.nullable(),
                                  channel_config_id:
                                    Zoi.integer(description: "Receiving channel config id.")
                                    |> Zoi.nullable(),
                                  retrieval_channel_id:
                                    Zoi.integer(description: "Retrieval channel id.")
                                    |> Zoi.nullable(),
                                  topic_id:
                                    Zoi.string(description: "Topic id, such as an IMAP mailbox.")
                                    |> Zoi.nullable(),
                                  routing_mode:
                                    Zoi.string(description: "Persisted routing mode."),
                                  configured_agent_id:
                                    Zoi.integer(
                                      description: "Configured agent id for agent routing."
                                    )
                                    |> Zoi.nullable()
                                })

  @rule_output_schema Zoi.object(%{
                        status:
                          Zoi.string(
                            description: "Write status, such as upserted, deleted, or noop."
                          ),
                        rule:
                          @persisted_rule_output_schema
                          |> Zoi.nullable(
                            description: "Persisted rule payload, or null when absent."
                          )
                      })

  @output_schema Zoi.object(%{
                   results: Zoi.list(@rule_output_schema, description: "Per-rule write results."),
                   count: Zoi.integer(description: "Number of commands applied.")
                 })

  use Zaq.Engine.Workflows.Action,
    name: "upsert_incoming_routing_rules",
    description:
      "Create, update, or clear incoming-message routing rules on the Engine node. Example rules: [%{channel_config_id: 12, topic_id: \"INBOX\", routing_mode: \"agent\", configured_agent_id: 34}]. Use routing_mode \"none\" to disable a scope and \"clear\" to delete a rule.",
    schema: @schema,
    output_schema: @output_schema

  alias Jido.Action.Tool
  alias Zaq.Event
  alias Zaq.MapUtils
  alias Zaq.NodeRouter

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, Tool.convert_params_using_schema(params, schema())}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @doc false
  def validate_rule(rule, _opts \\ [])

  def validate_rule(rule, _opts) when is_map(rule) do
    [
      validate_agent_destination(rule),
      validate_retrieval_scope(rule),
      validate_topic_scope(rule),
      validate_exclusive_scope(rule)
    ]
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  def validate_rule(_rule, _opts), do: {:error, "rule must be an object"}

  defp validate_agent_destination(%{routing_mode: "agent", configured_agent_id: nil}),
    do: {:error, "configured_agent_id is required when routing_mode is agent"}

  defp validate_agent_destination(%{routing_mode: "agent"} = rule) do
    if Map.has_key?(rule, :configured_agent_id),
      do: :ok,
      else: {:error, "configured_agent_id is required when routing_mode is agent"}
  end

  defp validate_agent_destination(_rule), do: :ok

  defp validate_retrieval_scope(%{retrieval_channel_id: id, channel_config_id: nil})
       when not is_nil(id),
       do: {:error, "channel_config_id is required when retrieval_channel_id is set"}

  defp validate_retrieval_scope(%{retrieval_channel_id: id} = rule) when not is_nil(id) do
    if Map.has_key?(rule, :channel_config_id),
      do: :ok,
      else: {:error, "channel_config_id is required when retrieval_channel_id is set"}
  end

  defp validate_retrieval_scope(_rule), do: :ok

  defp validate_topic_scope(%{topic_id: topic_id, channel_config_id: nil})
       when not is_nil(topic_id),
       do: {:error, "channel_config_id is required when topic_id is set"}

  defp validate_topic_scope(%{topic_id: topic_id} = rule) when not is_nil(topic_id) do
    if Map.has_key?(rule, :channel_config_id),
      do: :ok,
      else: {:error, "channel_config_id is required when topic_id is set"}
  end

  defp validate_topic_scope(_rule), do: :ok

  defp validate_exclusive_scope(%{retrieval_channel_id: retrieval_channel_id, topic_id: topic_id})
       when not is_nil(retrieval_channel_id) and not is_nil(topic_id),
       do: {:error, "retrieval_channel_id and topic_id cannot both be set"}

  defp validate_exclusive_scope(_rule), do: :ok

  @impl Jido.Action
  def run(params, context) when is_map(params) do
    rules = MapUtils.fetch(params, :rules)

    if is_list(rules) do
      dispatch_rules(rules, context)
    else
      {:error, "rules must be a list"}
    end
  end

  def run(_params, _context), do: {:error, "params must be a map"}

  defp dispatch_rules(rules, context) do
    event =
      Event.new(%{rules: rules}, :engine, opts: [action: :upsert_incoming_message_routing_rules])

    node_router = MapUtils.fetch(context || %{}, :node_router) || NodeRouter

    node_router.dispatch(event)
    |> Map.get(:response)
  end
end
