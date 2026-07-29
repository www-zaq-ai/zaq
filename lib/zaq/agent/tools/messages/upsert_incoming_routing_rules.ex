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

  use Zaq.Engine.Workflows.Action,
    name: "upsert_incoming_routing_rules",
    description:
      "Create, update, or clear incoming-message routing rules on the Engine node. Example rules: [%{channel_config_id: 12, topic_id: \"INBOX\", routing_mode: \"agent\", configured_agent_id: 34}]. Use routing_mode \"none\" to disable a scope and \"clear\" to delete a rule.",
    schema: [
      rules: [
        type: {:list, :map},
        required: true,
        doc:
          "List of routing rule commands. Example: [%{channel_config_id: 12, topic_id: \"INBOX\", routing_mode: \"agent\", configured_agent_id: 34}]. Scope keys: person_id, channel_config_id, retrieval_channel_id, topic_id. routing_mode: agent, none, or clear."
      ]
    ],
    output_schema: [
      results: [type: {:list, :map}, required: true, doc: "Per-rule write results."],
      count: [type: :integer, required: true, doc: "Number of commands applied."]
    ]

  alias Zaq.Event
  alias Zaq.MapUtils
  alias Zaq.NodeRouter

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
