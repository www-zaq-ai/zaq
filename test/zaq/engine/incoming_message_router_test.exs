defmodule Zaq.Engine.IncomingMessageRouterTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Engine.{IncomingMessageRouter, IncomingMessageRouting}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.SystemConfigFixtures

  defmodule RejectingIdentityResolver do
    def resolve(_incoming, _opts), do: {:error, :not_found}
    def person_payload(person), do: person
  end

  describe "route/1" do
    test "translates agent rule into an Agent hop" do
      agent = insert_agent!()

      {:ok, rule} =
        IncomingMessageRouting.upsert_rule(%{}, %{
          routing_mode: :agent,
          configured_agent_id: agent.id
        })

      routed = route(incoming(), pipeline_opts: [role_ids: [1]])

      assert routed.next_hop.destination == :agent
      assert routed.next_hop.type == :async
      assert routed.name == :incoming_message_agent_requested
      assert routed.opts == [action: :run_pipeline, pipeline_opts: [role_ids: [1]]]
      assert routed.assigns["agent_selection"] == %{"agent_id" => agent.id, "source" => "global"}

      assert routed.assigns["incoming_message_routing"] == %{
               "mode" => "agent",
               "source" => "global",
               "rule_id" => rule.id,
               "configured_agent_id" => agent.id,
               "person_resolved" => false,
               "channel_config_id" => nil,
               "retrieval_channel_id" => nil,
               "topic_id" => nil,
               "provider" => "mattermost"
             }
    end

    test "translates none rule into workflow-only event without a next hop" do
      {:ok, rule} = IncomingMessageRouting.upsert_rule(%{}, %{routing_mode: :none})

      routed = route(incoming())

      assert routed.next_hop == nil
      assert routed.name == :incoming_message_workflow_only
      assert routed.assigns["incoming_message_routing"]["mode"] == "none"
      assert routed.assigns["incoming_message_routing"]["rule_id"] == rule.id
      refute Map.has_key?(routed.assigns, "agent_selection")
    end

    test "default route keeps agent selection absent" do
      routed = route(incoming())

      assert routed.next_hop.destination == :agent
      assert routed.name == :incoming_message_agent_requested
      refute Map.has_key?(routed.assigns, "agent_selection")
      assert routed.assigns["incoming_message_routing"]["source"] == "default_zaq_agent"
    end
  end

  defp route(%Incoming{} = incoming, opts \\ []) do
    event_opts =
      opts
      |> Keyword.take([:pipeline_opts])
      |> Keyword.put(:action, :route_incoming_message)
      |> Keyword.put(:identity_resolver, RejectingIdentityResolver)

    incoming
    |> Event.new(:engine, opts: event_opts, actor: %{id: incoming.author_id})
    |> IncomingMessageRouter.route()
  end

  defp incoming do
    Incoming.new(%{
      content: "hello",
      channel_id: "ch1",
      author_id: "u1",
      provider: :mattermost
    })
  end

  defp insert_agent! do
    credential = SystemConfigFixtures.ai_credential_fixture()

    %ConfiguredAgent{}
    |> ConfiguredAgent.changeset(%{
      name: "Router Agent #{System.unique_integer([:positive, :monotonic])}",
      description: "",
      job: "Route incoming messages",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: true,
      active: true,
      advanced_options: %{}
    })
    |> Repo.insert!()
  end
end
