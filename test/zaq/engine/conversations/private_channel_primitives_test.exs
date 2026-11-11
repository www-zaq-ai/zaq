defmodule Zaq.Engine.Conversations.PrivateChannelPrimitivesTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryIngress}
  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations.{Conversation, ExecutionRecord, Message}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver

  setup do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Private input #{System.unique_integer([:positive])}",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert!()

    scope = %{
      provider: config.provider,
      channel_config_id: config.id,
      sender_id: "verified-sender"
    }

    %{config: config, scope: scope}
  end

  test "readiness and message resolution share connector-scoped identity without creating a chat",
       %{config: config, scope: scope} do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)
    assert {:ok, same} = IdentityResolver.resolve(input(config, scope), [])
    assert same.id == person.id
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0

    assert {:error, :unauthorized} =
             IdentityResolver.resolve_channel_sender(%{scope | provider: "mattermost"})
  end

  test "readiness rejects invalid or disabled scope before identity discovery", %{
    config: config,
    scope: scope
  } do
    for invalid <- [
          nil,
          %{},
          %{scope | sender_id: " "},
          %{scope | sender_id: nil},
          %{scope | channel_config_id: -1},
          %{scope | provider: "mattermost"}
        ] do
      assert {:error, :unauthorized} = IdentityResolver.resolve_channel_sender(invalid)
    end

    assert Repo.aggregate(Zaq.Accounts.Person, :count) == 0
    config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert {:error, :unauthorized} = IdentityResolver.resolve_channel_sender(scope)
    assert Repo.aggregate(Zaq.Accounts.Person, :count) == 0
  end

  test "preparation and ordinary admission use the same scoped binding without manufacturing execution",
       %{config: config, scope: scope} do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)
    incoming = input(config, scope)

    assert {:ok, prepared} =
             Conversations.prepare_channel_input(person, incoming, "Initial context")

    assert {:ok, repeated} =
             Conversations.prepare_channel_input(person, incoming, "Do not seed twice")

    assert repeated.routing_context.conversation_id == prepared.routing_context.conversation_id
    assert Repo.aggregate(Conversation, :count) == 1
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(ExecutionRecord, :count) == 0

    assert {:ok, binding} = Conversations.admit_incoming(prepared)
    assert binding.conversation_id == prepared.routing_context.conversation_id
    assert {:ok, _} = HistoryIngress.capture_resolved(prepared, person.id, :direct)

    assert {:ok, %{conversation: conversation, messages: messages}} =
             Conversations.restore_channel_conversation(
               person,
               scope,
               binding.conversation_id,
               []
             )

    assert conversation.id == binding.conversation_id
    assert Enum.map(messages, & &1.content) == ["Initial context", "Question"]
  end

  test "ordinary admission before preparation also reuses the binding and cannot reseed", %{
    config: config,
    scope: scope
  } do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)
    incoming = input(config, scope)
    incoming = %{incoming | person: IdentityResolver.person_payload(person)}
    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    assert {:ok, _} = HistoryIngress.capture_resolved(incoming, person.id, :direct)

    assert {:ok, prepared} =
             Conversations.prepare_channel_input(person, incoming, "Not a fresh chat")

    assert prepared.routing_context.conversation_id == binding.conversation_id
    assert Repo.aggregate(Message, :count) == 1
  end

  test "nested initial context capture publishes only from the completed preparation owner", %{
    config: config,
    scope: scope
  } do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)
    incoming = input(config, scope)
    assert {:ok, captured} = HistoryIngress.capture_resolved(incoming, person.id, :direct)
    id = captured.transcript_id
    Phoenix.PubSub.subscribe(Zaq.PubSub, ChannelHistoryUpdates.topic(id))

    assert {:ok, prepared} =
             Conversations.prepare_channel_input(person, incoming, "Initial context")

    context_id = Repo.get_by!(Message, content: "Initial context").id
    assert_receive {:channel_history_updated, ^id, [^context_id]}
    assert Repo.get!(Message, context_id).content == "Initial context"

    assert Repo.get!(Message, context_id).conversation_id ==
             prepared.routing_context.conversation_id

    refute_received {:channel_history_updated, _, [^context_id]}
  end

  test "outer rollback after successful preparation keeps context and UI invalidation uncommitted",
       %{
         config: config,
         scope: scope
       } do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)
    incoming = input(config, scope)
    assert {:ok, captured} = HistoryIngress.capture_resolved(incoming, person.id, :direct)
    id = captured.transcript_id
    Phoenix.PubSub.subscribe(Zaq.PubSub, ChannelHistoryUpdates.topic(id))

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = Conversations.prepare_channel_input(person, incoming, "Context")
               context_id = Repo.get_by!(Message, content: "Context").id
               send(self(), {:rolled_back_context, context_id})
               refute_received {:channel_history_updated, _, [^context_id]}
               Repo.rollback(:abort)
             end)

    refute Repo.get_by(Message, content: "Context")
    assert_received {:rolled_back_context, context_id}
    refute_received {:channel_history_updated, _, [^context_id]}
  end

  property "a caller-supplied Person cannot bypass sender binding", %{
    config: config,
    scope: scope
  } do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)

    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 16), max_runs: 10) do
      foreign = %{scope | sender_id: "foreign-#{suffix}"}

      assert {:error, :unauthorized} =
               Conversations.prepare_channel_input(person, input(config, foreign), nil)

      assert {:error, :unauthorized} =
               Conversations.restore_channel_conversation(
                 person,
                 foreign,
                 Ecto.UUID.generate(),
                 []
               )
    end

    assert Repo.aggregate(Conversation, :count) == 0
  end

  test "archived chats and inactive People fail closed without creating replacements", %{
    config: config,
    scope: scope
  } do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)

    assert {:ok, incoming} =
             Conversations.prepare_channel_input(person, input(config, scope), "Context")

    id = incoming.routing_context.conversation_id
    assert {:ok, _} = Conversations.archive_conversation(Conversations.get_conversation(id))

    assert {:error, :conversation_not_found} =
             Conversations.restore_channel_conversation(person, scope, id, [])

    assert {:error, :conversation_not_found} =
             Conversations.prepare_channel_input(person, incoming, nil)

    person |> Ecto.Changeset.change(status: "inactive") |> Repo.update!()

    assert {:error, :unauthorized} =
             Conversations.prepare_channel_input(person, input(config, scope), nil)

    assert Repo.aggregate(Conversation, :count) == 1
  end

  defp input(config, scope) do
    Incoming.new(%{
      provider: :web_widget,
      author_id: scope.sender_id,
      channel_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      content: "Question",
      routing_context: %{channel_config_id: config.id, conversation_type: :one_to_one}
    })
    |> CommunicationBridge.put_conversation_identity()
  end

  test "missing or fabricated Person declarations never authorize private preparation or history",
       %{config: config, scope: scope} do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)

    for invalid <- [nil, %{id: person.id}, %Zaq.Accounts.Person{id: 0}] do
      assert {:error, :unauthorized} = IdentityResolver.authorize_channel_sender(invalid, scope)

      assert {:error, :unauthorized} =
               Conversations.prepare_channel_input(invalid, input(config, scope), "Context")

      assert {:error, :unauthorized} =
               Conversations.restore_channel_conversation(
                 invalid,
                 scope,
                 Ecto.UUID.generate(),
                 []
               )
    end

    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(ExecutionRecord, :count) == 0
  end

  test "failed canonical context capture rolls back the shared binding and seed", %{
    config: config,
    scope: scope
  } do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)
    incoming = input(config, scope)
    incoming = %{incoming | routing_context: %{incoming.routing_context | source_scope: :invalid}}
    assert {:error, _} = Conversations.prepare_channel_input(person, incoming, "Context")
    assert Repo.aggregate(Conversation, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Zaq.Engine.Conversations.Transcript, :count) == 0
    assert Repo.aggregate(ExecutionRecord, :count) == 0
  end

  property "capture facts from an envelope equal the explicit canonical coordinates", %{
    config: config,
    scope: scope
  } do
    alias Zaq.Engine.History.Facts
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)

    check all(channel <- string(:alphanumeric, min_length: 1, max_length: 24), max_runs: 10) do
      incoming = %{input(config, scope) | channel_id: channel}

      assert Facts.for_capture(incoming, person.id, :direct) ==
               Facts.for_capture(%{
                 provider: "web_widget",
                 channel_config_id: config.id,
                 channel_id: channel,
                 conversation_id: nil,
                 actor_person_id: person.id,
                 kind: :direct,
                 recipient_person_ids: [],
                 thread_id: nil
               })
    end
  end

  test "restoration rejects inconsistent provider coordinates even when scope omits provider", %{
    config: config,
    scope: scope
  } do
    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)

    assert {:ok, incoming} =
             Conversations.prepare_channel_input(person, input(config, scope), "Context")

    id = incoming.routing_context.conversation_id

    Conversations.get_conversation(id)
    |> Ecto.Changeset.change(channel_type: "mattermost")
    |> Repo.update!()

    assert {:error, :conversation_not_found} =
             Conversations.restore_channel_conversation(
               person,
               Map.delete(scope, :provider),
               id,
               []
             )
  end
end
