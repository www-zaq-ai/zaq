defmodule Zaq.Engine.Conversations.MessageAttributionTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Messages.Incoming

  test "admission persists the resolved author and source time rather than supplied metadata" do
    {:ok, person} = People.create_person(%{full_name: "Directory author"})
    sent_at = ~U[2026-01-02 03:04:05.123456Z]

    incoming =
      Incoming.new(%{
        provider: :web,
        channel_id: "bo",
        author_id: "channel-author",
        author_name: "Channel name",
        person: person,
        content: "Unmodified body",
        routing_context: %{provider_sent_at: sent_at},
        metadata: %{"author_person_id" => person.id + 1}
      })

    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    stored = Repo.get!(Message, binding.user_message_id)
    assert stored.history_context["author_person_id"] == person.id
    assert stored.provider_sent_at == sent_at
    assert stored.content == incoming.content
    assert stored.author_id == incoming.author_id
    assert is_nil(stored.author_name)
  end

  test "admission without author or source time does not infer them from the conversation" do
    incoming =
      Incoming.new(%{
        provider: :web,
        channel_id: "bo",
        author_id: "unknown",
        content: "No source time"
      })

    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    stored = Repo.get!(Message, binding.user_message_id)
    assert is_nil(stored.history_context["author_person_id"])
    assert is_nil(stored.provider_sent_at)
    assert %DateTime{} = stored.inserted_at
  end

  test "message reads expose directory authors and persisted timestamp provenance" do
    {:ok, person} = People.create_person(%{full_name: "Directory author"})
    sent_at = ~U[2026-01-02 03:04:05.123456Z]

    incoming =
      Incoming.new(%{
        provider: :web,
        channel_id: "bo",
        author_id: "author",
        person: person,
        content: "Provider timed body",
        routing_context: %{provider_sent_at: sent_at}
      })

    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    conversation = Conversations.get_conversation!(binding.conversation_id)

    assert {:ok, recorded} =
             Conversations.add_message(conversation, %{role: "assistant", content: "Answer"})

    assert [input, answer] = Conversations.list_messages(conversation)
    assert input.author.name == person.full_name
    assert input.author.person_id == person.id
    assert input.timestamp == %{value: sent_at, source: :provider}
    assert answer.author.name == "Assistant"
    assert answer.timestamp == %{value: recorded.inserted_at, source: :recorded}
    assert input.content == incoming.content
  end

  property "ordinary message attributes cannot stamp trusted authorship or source time" do
    check all(person_id <- positive_integer(), name <- string(:printable)) do
      changeset =
        Message.changeset(%Message{}, %{
          conversation_id: Ecto.UUID.generate(),
          role: "user",
          content: "Body",
          history_context: %{"author_person_id" => person_id},
          author_name: name,
          provider_sent_at: ~U[2026-01-02 03:04:05.123456Z]
        })

      assert changeset.valid?
      stored = Ecto.Changeset.apply_changes(changeset)
      assert stored.history_context == %{}
      assert is_nil(stored.provider_sent_at)
      assert is_nil(stored.author_name)
    end
  end

  test "authorized legacy admission exposes the persisted input without private metadata" do
    {:ok, person} = People.create_person(%{full_name: "Directory author"})

    incoming = Incoming.new(%{provider: :web, channel_id: "bo", person: person, content: "Input"})
    assert {:ok, binding} = Conversations.admit_incoming(incoming)

    assert {:ok, %{kind: :legacy, input: input}} =
             Conversations.admit_execution(binding, %{person: %{id: person.id}}, incoming.content)

    stored = Repo.get!(Message, binding.user_message_id)
    assert input.id == stored.id
    assert input.author.name == person.full_name
    assert input.timestamp == %{value: stored.inserted_at, source: :recorded}
    refute Map.has_key?(input, :metadata)
    refute Map.has_key?(input, :trace)
  end

  test "legacy agent history retains completion filtering and supplies recorded timestamps" do
    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "bo", title: "History"})

    assert {:ok, completed} =
             Conversations.add_message(conversation, %{role: "user", content: "Completed"})

    assert {:ok, _pending} =
             Conversations.add_message(conversation, %{
               role: "user",
               content: "Pending",
               metadata: %{"execution_status" => "pending"}
             })

    assert [message] = Conversations.list_agent_history(%{conversation_id: conversation.id})
    assert message.id == completed.id
    assert message.author.name == "Unknown author"
    assert message.timestamp == %{value: completed.inserted_at, source: :recorded}
  end
end
