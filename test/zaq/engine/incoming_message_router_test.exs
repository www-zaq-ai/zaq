defmodule Zaq.Engine.IncomingMessageRouterTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.EventNames
  alias Zaq.Engine.{IncomingMessageRouter, IncomingMessageRouting}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Identity.ExecutionActor
  alias Zaq.SystemConfigFixtures

  defmodule StubConversations do
    def admit_incoming(_incoming) do
      {:ok,
       %{
         conversation_id: "00000000-0000-0000-0000-000000000001",
         user_message_id: "00000000-0000-0000-0000-000000000002",
         finalization_token: "00000000-0000-0000-0000-000000000003",
         admitted?: true
       }}
    end
  end

  defmodule RejectingIdentityResolver do
    def resolve(_incoming, _opts), do: {:error, :not_found}
    def person_payload(person), do: person
  end

  defmodule ResolvingIdentityResolver do
    def resolve(_incoming, _opts), do: {:ok, %{id: 42, full_name: "Resolved", team_ids: [3]}}
    def person_payload(person), do: person
  end

  defmodule RecordingNodeRouter do
    def fire(event) do
      send(self(), {:node_router_fire, event})
      event
    end
  end

  describe "route/1" do
    test "invalid Incoming Person cannot be normalized or downgraded to a channel actor" do
      for person <- [%{"id" => 2, id: 1}, %{id: "bad"}, %{}],
          resolver <- [RejectingIdentityResolver, ResolvingIdentityResolver] do
        event =
          Event.new(%{incoming() | person: person}, :engine, opts: [identity_resolver: resolver])

        routed = IncomingMessageRouter.route(event)
        assert {:error, :invalid_execution_actor} = ExecutionActor.validate(routed.actor)
      end
    end

    test "promotes a trusted BO origin after Person resolution without a conflicting kind" do
      actor = %{kind: :bo_user, subject: "7", user_id: 7}

      event =
        Event.new(incoming(%{provider: :web}), :engine,
          actor: actor,
          opts: [
            identity_resolver: ResolvingIdentityResolver,
            conversations_module: StubConversations
          ]
        )

      routed = IncomingMessageRouter.route(event)
      assert routed.actor.person == %{id: 42, full_name: "Resolved", team_ids: [3]}
      assert routed.actor.user_id == 7
      refute Map.has_key?(routed.actor, :kind)
      refute Map.has_key?(routed.actor, :subject)
      assert {:ok, {:person, 42}} = ExecutionActor.identity(routed.actor)
    end

    test "retains an unresolved explicit BO identity rather than replacing it with a channel" do
      actor = %{"kind" => "bo_user", "subject" => "7"}

      event =
        Event.new(incoming(%{provider: :web}), :engine,
          actor: actor,
          opts: [identity_resolver: RejectingIdentityResolver]
        )

      assert IncomingMessageRouter.route(event).actor == actor
    end

    test "blank authors and malformed actor containers do not acquire identities" do
      assert {:error, _} =
               ExecutionActor.validate(route(incoming(%{author_id: " "})).actor)

      event =
        Event.new(incoming(), :engine,
          actor: [],
          opts: [identity_resolver: RejectingIdentityResolver]
        )

      assert IncomingMessageRouter.route(event).actor == []
    end

    test "does not normalize away malformed or conflicting actor declarations" do
      for actor <- [
            %{person: %{id: "bad"}},
            %{"person" => %{"id" => 2}, person: %{id: 1}},
            %{person: %{id: 1}, kind: :system, subject: "forged"}
          ] do
        event =
          Event.new(incoming(), :engine,
            actor: actor,
            opts: [identity_resolver: RejectingIdentityResolver]
          )

        assert IncomingMessageRouter.route(event).actor == actor
      end
    end

    test "finalizes unresolved channel identity using provider, config and author" do
      routed = route(incoming(%{routing_context: %{channel_config_id: 42}}))

      assert {:ok, {:channel_subject, subject}} =
               ExecutionActor.identity(routed.actor)

      assert Jason.decode!(subject) == ["mattermost", 42, "u1"]
      other = route(incoming(%{routing_context: %{channel_config_id: 43}}))
      refute other.actor.subject == subject
    end

    test "retains Person identity without adding an explicit nonperson declaration" do
      person = %{id: 42, full_name: "Person", team_ids: [3]}
      routed = route(incoming(%{person: person}))
      assert routed.actor.person == person
      refute Map.has_key?(routed.actor, :kind)
    end

    test "missing channel author cannot become a system or shared anonymous actor" do
      routed = route(incoming(%{author_id: nil}))

      assert {:error, :invalid_execution_actor} =
               ExecutionActor.validate(routed.actor)
    end

    test "translates agent rule into an Agent hop" do
      agent = insert_agent!()

      {:ok, rule} =
        IncomingMessageRouting.upsert_rule(%{}, %{
          routing_mode: :agent,
          configured_agent_id: agent.id
        })

      routed =
        route(incoming(),
          pipeline_opts: [role_ids: [1]],
          conversations_module: Zaq.Engine.Conversations
        )

      assert routed.next_hop.destination == :agent
      assert routed.next_hop.type == :async
      assert routed.name == EventNames.message_received(routed.request, :agent_requested)
      assert routed.opts == [action: :run_pipeline, pipeline_opts: [role_ids: [1]]]
      assert routed.assigns["agent_selection"] == %{"agent_id" => agent.id, "source" => "global"}

      assert %{
               "conversation_id" => conversation_id,
               "user_message_id" => user_message_id,
               "finalization_token" => finalization_token
             } = routed.assigns["conversation_binding"]

      assert is_binary(finalization_token)

      assert %{conversation_id: ^conversation_id, content: "hello", role: "user"} =
               Repo.get(Zaq.Engine.Conversations.Message, user_message_id)

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

    test "suppresses provider redelivery after the input has already been admitted" do
      incoming = incoming(%{message_id: "provider-redelivery-1"})

      first = route(incoming, conversations_module: Zaq.Engine.Conversations)
      second = route(incoming, conversations_module: Zaq.Engine.Conversations)

      assert first.next_hop.destination == :agent
      assert second.next_hop == nil
      assert second.response == {:ok, :duplicate_incoming}
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
      |> Keyword.take([:pipeline_opts, :agent_hop_type, :node_router, :conversations_module])
      |> Keyword.put(:action, :route_incoming_message)
      |> Keyword.put(:identity_resolver, RejectingIdentityResolver)
      |> Keyword.put_new(:conversations_module, StubConversations)

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
