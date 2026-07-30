defmodule Zaq.Engine.IncomingMessageRouterTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.EventNames
  alias Zaq.Engine.{IncomingMessageRouter, IncomingMessageRouting}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.SystemConfigFixtures

  defmodule RejectingIdentityResolver do
    def resolve(_incoming, _opts), do: {:error, :not_found}
    def person_payload(person), do: person
  end

  defmodule RecordingNodeRouter do
    def fire(event) do
      send(self(), {:node_router_fire, event})
      event
    end
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
      assert routed.name == EventNames.message_received(routed.request, :agent_requested)
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

    test "can route the final agent hop synchronously" do
      agent = insert_agent!()

      {:ok, _rule} =
        IncomingMessageRouting.upsert_rule(%{}, %{
          routing_mode: :agent,
          configured_agent_id: agent.id
        })

      routed = route(incoming(), agent_hop_type: :sync)

      assert routed.next_hop.destination == :agent
      assert routed.next_hop.type == :sync
      assert routed.opts[:action] == :run_pipeline
    end

    test "translates none rule into workflow-only event for trigger broadcast" do
      {:ok, rule} = IncomingMessageRouting.upsert_rule(%{}, %{routing_mode: :none})

      routed = route(incoming(), node_router: RecordingNodeRouter)

      assert routed.next_hop == nil
      assert routed.opts[:action] == :route_incoming_message
      assert routed.name == EventNames.message_received(routed.request, :workflow_only)
      assert routed.assigns["incoming_message_routing"]["mode"] == "none"
      assert routed.assigns["incoming_message_routing"]["rule_id"] == rule.id
      refute Map.has_key?(routed.assigns, "agent_selection")

      assert_receive {:node_router_fire, ^routed}
    end

    test "default route keeps agent selection absent" do
      routed = route(incoming())

      assert routed.next_hop.destination == :agent
      assert routed.name == EventNames.message_received(routed.request, :agent_requested)
      refute Map.has_key?(routed.assigns, "agent_selection")
      assert routed.assigns["incoming_message_routing"]["source"] == "default_zaq_agent"
    end

    test "uses routing context channel config id in restored channel event name" do
      routed = route(incoming(%{routing_context: %{channel_config_id: 42}}))

      assert routed.name == "channels:message_received.agent_requested.mattermost.42"
      assert routed.assigns["incoming_message_routing"]["channel_config_id"] == 42
    end
  end

  defp route(%Incoming{} = incoming, opts \\ []) do
    event_opts =
      opts
      |> Keyword.take([:pipeline_opts, :agent_hop_type, :node_router])
      |> Keyword.put(:action, :route_incoming_message)
      |> Keyword.put(:identity_resolver, RejectingIdentityResolver)

    incoming
    |> Event.new(:engine, opts: event_opts, actor: %{id: incoming.author_id})
    |> IncomingMessageRouter.route()
  end

  defp incoming(attrs \\ %{}) do
    %{
      content: "hello",
      channel_id: "ch1",
      author_id: "u1",
      provider: :mattermost
    }
    |> Map.merge(attrs)
    |> Incoming.new()
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
