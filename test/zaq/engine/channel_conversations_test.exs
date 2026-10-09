defmodule Zaq.Engine.ChannelConversationsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.Web.{Command, Context, Response}
  alias Zaq.Channels.Web.Message, as: WebMessage
  alias Zaq.Engine.{Api, ChannelConversations, Conversations, HistoryIngress}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations.{Conversation, Message, Transcript, TranscriptMessage}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Event
  alias Zaq.People.IdentityResolver
  alias Zaq.Permissions
  alias Zaq.SystemConfigFixtures

  setup do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    {:ok, config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Widget #{System.unique_integer([:positive])}",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert()

    %{config: config, scope: %{channel_config_id: config.id, sender_id: "parent-user-1"}}
  end

  test "initialization resolves a channel Person but creates no chat or history", %{scope: scope} do
    assert {:ok, %{conversation_id: nil, created: false}} = ChannelConversations.initialize(scope)

    assert {:ok, %{status: "active"}} =
             People.match_by_channel("web_widget", scope.sender_id, scope.channel_config_id)

    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Transcript, :count) == 0
    assert Repo.aggregate(TranscriptMessage, :count) == 0
  end

  test "the same external sender is connector-scoped", %{scope: scope} do
    other = config()
    assert {:ok, _} = ChannelConversations.initialize(scope)
    assert {:ok, _} = ChannelConversations.initialize(%{scope | channel_config_id: other.id})

    assert {:ok, first} =
             People.match_by_channel("web_widget", scope.sender_id, scope.channel_config_id)

    assert {:ok, second} = People.match_by_channel("web_widget", scope.sender_id, other.id)
    refute first.id == second.id
  end

  property "generated external senders cannot resume across configuration boundaries", %{
    config: config
  } do
    other = config()

    check all(identifier <- string(:alphanumeric, min_length: 1, max_length: 24), max_runs: 10) do
      scope = %{channel_config_id: config.id, sender_id: "external-#{identifier}"}
      before = Repo.aggregate(Conversation, :count)
      assert {:ok, %{conversation_id: nil}} = ChannelConversations.initialize(scope)
      assert Repo.aggregate(Conversation, :count) == before
      {conversation, _transcript, _message} = chat(config, scope)
      assert {:ok, [_]} = ChannelConversations.history(scope, conversation.id)
      foreign = %{scope | channel_config_id: other.id}

      assert {:error, :conversation_not_found} =
               ChannelConversations.history(foreign, conversation.id)

      assert {:error, :conversation_not_found} =
               ChannelConversations.initialize(foreign, conversation.id)
    end
  end

  test "a received question creates its chat and seeds ordinary user history before admission", %{
    config: config,
    scope: scope
  } do
    incoming = incoming(config, scope)

    assert {:ok, prepared} =
             ChannelConversations.prepare(scope, incoming, "Parent application context")

    id = prepared.routing_context.conversation_id

    assert [%Message{role: "user", content: "Parent application context", metadata: %{}}] =
             Conversations.list_messages(Conversations.get_conversation(id))

    assert {:ok, binding} = Conversations.admit_incoming(prepared)
    assert binding.conversation_id == id

    assert {:ok, _} =
             HistoryIngress.capture_resolved(prepared, Incoming.person_id(prepared), :direct)

    assert {:ok,
            [
              %{position: 1, content: "Parent application context"},
              %{position: 2, content: "First question"}
            ]} =
             ChannelConversations.history(scope, id)

    assert {:ok, _} = ChannelConversations.prepare(scope, prepared, "Do not seed again")
    assert Repo.aggregate(Message, :count) == 2
  end

  test "invalid question or conflicting sender creates no conversation or seed", %{
    config: config,
    scope: scope
  } do
    incoming = incoming(config, scope)

    for invalid <- [%{incoming | content: " "}, %{incoming | author_id: "forged-user"}] do
      assert {:error, :invalid_request} = ChannelConversations.prepare(scope, invalid, "Context")
    end

    assert {:error, :invalid_request} = ChannelConversations.prepare(scope, incoming, " ")
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "first-message admission and canonical capture reuse one stored user message", %{
    config: config,
    scope: scope
  } do
    {conversation, transcript_id, message_id} = chat(config, scope)
    assert conversation.channel_type == "web_widget"
    assert conversation.channel_config_id == config.id
    assert Repo.aggregate(Message, :count) == 1

    assert {:ok, [%{message_id: ^message_id, content: "First question"}]} =
             ChannelConversations.history(scope, conversation.id)

    assert Repo.get!(Transcript, transcript_id).strategy == "direct"

    assert {:ok, %{conversation_id: id, created: false}} =
             ChannelConversations.initialize(scope, conversation.id)

    assert id == conversation.id
  end

  test "non-private communication facts cannot create a private chat or seed", %{
    config: config,
    scope: scope
  } do
    incoming = incoming(config, scope)

    for type <- [nil, :room, :recipient_addressed] do
      invalid = %{
        incoming
        | routing_context: %{incoming.routing_context | conversation_type: type}
      }

      assert {:error, :invalid_request} = ChannelConversations.prepare(scope, invalid, "Context")
    end

    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "foreign sender, foreign config and unknown IDs cannot resume or read a chat", %{
    config: config,
    scope: scope
  } do
    {conversation, _transcript, _message} = chat(config, scope)
    other = config()

    for foreign <- [%{scope | sender_id: "parent-user-2"}, %{scope | channel_config_id: other.id}] do
      assert {:error, :conversation_not_found} =
               ChannelConversations.initialize(foreign, conversation.id)

      assert {:error, :conversation_not_found} =
               ChannelConversations.history(foreign, conversation.id)
    end

    assert {:error, :conversation_not_found} =
             ChannelConversations.initialize(scope, Ecto.UUID.generate())

    assert {:error, :conversation_not_found} = ChannelConversations.history(scope, "invalid-id")
    assert Repo.aggregate(Conversation, :count) == 1
  end

  test "unbound and legacy history cannot fall back to unrestricted conversation reads", %{
    scope: scope
  } do
    assert {:ok, _} = ChannelConversations.initialize(scope)

    {:ok, person} =
      People.match_by_channel("web_widget", scope.sender_id, scope.channel_config_id)

    {:ok, conversation} =
      Conversations.create_conversation(%{
        channel_type: "web_widget",
        channel_config_id: scope.channel_config_id,
        channel_user_id: scope.sender_id,
        person_id: person.id,
        external_channel_id: Ecto.UUID.generate()
      })

    assert {:error, :conversation_not_found} =
             ChannelConversations.history(scope, conversation.id)

    assert {:error, :conversation_not_found} =
             ChannelConversations.initialize(scope, conversation.id)
  end

  test "revoked canonical grants deny resume and history without recreating grants", %{
    config: config,
    scope: scope
  } do
    {conversation, transcript_id, _message} = chat(config, scope)
    transcript = Repo.get!(Transcript, transcript_id)
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}
    [grant] = Permissions.list_direct(resource)
    assert :ok = Permissions.revoke(resource, grant)

    assert {:error, :conversation_not_found} =
             ChannelConversations.history(scope, conversation.id)

    assert {:error, :conversation_not_found} =
             ChannelConversations.initialize(scope, conversation.id)

    assert Permissions.list_direct(resource) == []
  end

  test "canonical bounds and safe projections are retained", %{config: config, scope: scope} do
    {conversation, _transcript, _message} = chat(config, scope)
    assert {:ok, []} = ChannelConversations.history(scope, conversation.id, after_position: 1)

    assert {:error, :invalid_cursor} =
             ChannelConversations.history(scope, conversation.id, limit: 101)

    assert {:ok, [message]} = ChannelConversations.history(scope, conversation.id, limit: 1)
    refute Map.has_key?(message, :metadata)
    refute Map.has_key?(message, :trace)
  end

  test "disabled configurations and malformed or inactive identities fail closed", %{
    config: config,
    scope: scope
  } do
    assert {:error, :unauthorized} = ChannelConversations.initialize(%{scope | sender_id: ""})

    assert {:error, :unauthorized} =
             ChannelConversations.initialize(%{scope | channel_config_id: -1})

    assert {:ok, _} = ChannelConversations.initialize(scope)
    {:ok, person} = People.match_by_channel("web_widget", scope.sender_id, config.id)
    person |> Ecto.Changeset.change(status: "inactive") |> Repo.update!()
    assert {:error, :unauthorized} = ChannelConversations.initialize(scope)
    config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    assert {:error, :unauthorized} =
             ChannelConversations.initialize(%{scope | sender_id: "new-user"})

    assert Repo.aggregate(Conversation, :count) == 0
  end

  test "Engine role exposes a fixed domain action, not arbitrary conversation operations", %{
    scope: scope
  } do
    event =
      Event.new(Map.put(scope, :operation, :initialize), :engine,
        opts: [action: :channel_conversations]
      )

    assert {:ok, %{conversation_id: nil, created: false}} =
             Api.handle_event(event, :channel_conversations, nil).response

    bad = %{event | request: Map.put(scope, :operation, :delete)}

    assert {:error, :invalid_request} =
             Api.handle_event(bad, :channel_conversations, nil).response
  end

  test "shared widget command reaches the authorized Engine boundary without creating a chat", %{
    scope: scope
  } do
    context = widget_context(scope)
    {:ok, command} = Command.new(%{request_id: "widget-init", type: :conversation_init})

    assert %Response{type: :widget_initialized, conversation_id: nil, payload: %{created: false}} =
             web_ingress(command, context)

    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Transcript, :count) == 0
  end

  test "shared widget history and resume preserve canonical authorization", %{
    config: config,
    scope: scope
  } do
    {conversation, _transcript, message_id} = chat(config, scope)
    context = widget_context(scope)

    {:ok, command} =
      Command.new(%{
        request_id: "widget-history",
        type: :conversation_history,
        conversation_id: conversation.id,
        params: %{limit: 1}
      })

    assert %Response{
             type: :conversation_history,
             payload: %{messages: [%{message_id: ^message_id}]}
           } =
             web_ingress(command, context)

    foreign = widget_context(%{scope | sender_id: "another-sender"})

    assert %Response{type: :error, payload: %{code: :conversation_not_found}} =
             web_ingress(command, foreign)
  end

  test "widget ingress rejects forged bypass and conflicting payload sender before persistence",
       %{scope: scope} do
    context = widget_context(scope)
    {:ok, command} = Command.new(%{request_id: "widget-init", type: :conversation_init})
    forged = %{context | capabilities: MapSet.new([:skip_permissions])}
    assert {:error, :forbidden_widget_options} = web_ingress(command, forged)

    {:ok, message} =
      WebMessage.new(%{
        request_id: "forged",
        message_id: "forged",
        content: "Question",
        timestamp: DateTime.utc_now(),
        channel: "default",
        mode: :sync,
        author_id: "different-user"
      })

    assert {:error, :unauthorized} = web_ingress(message, context)
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "real Engine routing preserves the lazy binding without duplicate history", %{
    config: config,
    scope: scope
  } do
    credential = SystemConfigFixtures.ai_credential_fixture()

    agent =
      %ConfiguredAgent{}
      |> ConfiguredAgent.changeset(%{
        name: "Widget agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Answer questions",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true
      })
      |> Repo.insert!()

    assert {:ok, _rule} =
             IncomingMessageRouting.upsert_rule(
               %{channel_config_id: config.id},
               %{routing_mode: :agent, configured_agent_id: agent.id}
             )

    assert {:ok, prepared} =
             ChannelConversations.prepare(scope, incoming(config, scope), "Context")

    event =
      Event.new(prepared, :engine,
        actor: %{person: prepared.person},
        opts: [action: :route_incoming_message, capture_history: true]
      )

    routed = Api.handle_event(event, :route_incoming_message, nil)
    assert routed.next_hop.destination == :agent

    assert routed.assigns["conversation_binding"]["conversation_id"] ==
             prepared.routing_context.conversation_id

    assert Repo.aggregate(Message, :count) == 2

    assert {:ok, [%{content: "Context"}, %{content: "First question"}]} =
             ChannelConversations.history(scope, prepared.routing_context.conversation_id)
  end

  test "deleted transcript denies resume and message preparation without replacement", %{
    config: config,
    scope: scope
  } do
    {conversation, transcript_id, _message} = chat(config, scope)
    Repo.delete_all(from tm in TranscriptMessage, where: tm.transcript_id == ^transcript_id)
    Repo.get!(Transcript, transcript_id) |> Repo.delete!()
    question = incoming(config, scope)

    question = %{
      question
      | routing_context: %{question.routing_context | conversation_id: conversation.id}
    }

    assert {:error, :conversation_not_found} =
             ChannelConversations.initialize(scope, conversation.id)

    assert {:error, :conversation_not_found} =
             ChannelConversations.history(scope, conversation.id)

    assert {:error, :conversation_not_found} =
             ChannelConversations.prepare(scope, question, "Do not seed")

    assert Repo.aggregate(Conversation, :count) == 1
    assert Repo.aggregate(Message, :count) == 1
  end

  test "deleted conversation is not silently replaced on the next question", %{
    config: config,
    scope: scope
  } do
    {conversation, transcript_id, _message} = chat(config, scope)
    Repo.delete_all(from tm in TranscriptMessage, where: tm.transcript_id == ^transcript_id)
    Repo.delete!(conversation)
    question = incoming(config, scope)

    question = %{
      question
      | routing_context: %{question.routing_context | conversation_id: conversation.id}
    }

    assert {:error, :conversation_not_found} = ChannelConversations.prepare(scope, question)

    assert {:error, :conversation_not_found} =
             ChannelConversations.initialize(scope, conversation.id)

    assert Repo.aggregate(Conversation, :count) == 0
  end

  test "failed canonical seed capture rolls back conversation and ordinary seed", %{
    config: config,
    scope: scope
  } do
    question = incoming(config, scope)
    question = %{question | routing_context: %{question.routing_context | source_scope: :invalid}}
    assert {:error, _reason} = ChannelConversations.prepare(scope, question, "Context")
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Transcript, :count) == 0
  end

  test "resume restores native channel coordinates without trusting a new payload coordinate", %{
    config: config,
    scope: scope
  } do
    {conversation, _transcript, _message} = chat(config, scope)
    question = incoming(config, scope)
    refute question.channel_id == conversation.external_channel_id

    question = %{
      question
      | routing_context: %{question.routing_context | conversation_id: conversation.id}
    }

    assert {:ok, prepared} = ChannelConversations.prepare(scope, question, "Ignored resume seed")
    assert prepared.channel_id == conversation.external_channel_id
    assert prepared.metadata["conversation"]["channel_id"] == conversation.external_channel_id
    assert Repo.aggregate(Message, :count) == 1
  end

  test "widget readiness rejects a trusted ID belonging to another provider" do
    {:ok, other} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Foreign connector",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://mattermost.example.test",
        token: "fixture-only"
      })
      |> Repo.insert()

    context = widget_context(%{channel_config_id: other.id, sender_id: "sender"})
    {:ok, command} = Command.new(%{request_id: "foreign-init", type: :conversation_init})

    assert %Response{type: :error, payload: %{code: :unauthorized}} =
             web_ingress(command, context)

    assert Repo.aggregate(Conversation, :count) == 0
  end

  defp widget_context(scope) do
    {:ok, context} =
      Context.new(nil,
        consumer: :widget,
        sender_id: scope.sender_id,
        channel_config_id: scope.channel_config_id
      )

    context
  end

  defp web_ingress(payload, context) do
    event =
      Event.new(%{payload: payload, context: context}, :channels,
        actor: context.actor,
        opts: [action: :web_ingress]
      )

    Zaq.Channels.Api.handle_event(event, :web_ingress, nil).response
  end

  defp chat(config, scope) do
    assert {:ok, _} = ChannelConversations.initialize(scope)
    incoming = incoming(config, scope)
    assert {:ok, person} = IdentityResolver.resolve(incoming, [])
    incoming = %{incoming | person: IdentityResolver.person_payload(person)}
    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    assert {:ok, capture} = HistoryIngress.capture_resolved(incoming, person.id, :direct)
    assert capture.message_id == binding.user_message_id

    {Conversations.get_conversation(binding.conversation_id), capture.transcript_id,
     binding.user_message_id}
  end

  defp incoming(config, scope) do
    Incoming.new(%{
      provider: :web_widget,
      author_id: scope.sender_id,
      channel_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      content: "First question",
      routing_context: %RoutingContext{
        channel_config_id: config.id,
        conversation_type: :one_to_one
      }
    })
    |> CommunicationBridge.put_conversation_identity()
  end

  defp config do
    {:ok, config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Other widget #{System.unique_integer([:positive])}",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert()

    config
  end
end
