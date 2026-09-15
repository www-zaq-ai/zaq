defmodule Zaq.Engine.ConversationPeoplePersistenceTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.MessageRating

  test "literal ownership bounds retrieval and count, including archived history" do
    {:ok, owner} = People.create_person(%{full_name: "Owner"})
    {:ok, other} = People.create_person(%{full_name: "Other"})
    active = conversation(owner.id, "active")
    archived = conversation(owner.id, "archived")
    foreign = conversation(other.id, "active")
    legacy = conversation(nil, "active")

    assert Conversations.count_conversations(person_id: owner.id) == 2
    assert Conversations.count_conversations(person_id: owner.id, status: "archived") == 1
    assert Conversations.get_person_conversation(active.id, owner.id).id == active.id
    assert Conversations.get_person_conversation(archived.id, owner.id).id == archived.id
    assert Conversations.get_person_conversation(foreign.id, owner.id) == nil
    assert Conversations.get_person_conversation(legacy.id, owner.id) == nil
    assert Conversations.get_person_conversation(active.id, nil) == nil

    ordered = Conversations.list_conversations(person_id: owner.id)
    assert length(ordered) == 2

    assert Conversations.list_conversations(person_id: owner.id, limit: 1, offset: 1) ==
             Enum.drop(ordered, 1)
  end

  property "malformed conversation coordinates fail closed" do
    check all(id <- string(:alphanumeric, max_length: 30)) do
      assert Conversations.get_person_conversation(id, 1) == nil
      assert Conversations.get_person_conversation(id, nil) == nil
    end
  end

  test "Person ratings remain isolated and merges retain survivor feedback and transfer other rows" do
    {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    {:ok, loser} = People.create_person(%{full_name: "Loser"})
    conv = conversation(loser.id, "active")
    {:ok, first} = Conversations.add_message(conv, %{role: "assistant", content: "First"})
    {:ok, second} = Conversations.add_message(conv, %{role: "assistant", content: "Second"})

    {:ok, retained} =
      Conversations.rate_message_by_id(first.id, %{person_id: survivor.id, rating: 5})

    {:ok, discarded} =
      Conversations.rate_message_by_id(first.id, %{person_id: loser.id, rating: 1})

    {:ok, transferred} =
      Conversations.rate_message_by_id(second.id, %{person_id: loser.id, rating: 4})

    assert Conversations.get_rating(first, %{person_id: survivor.id}).id == retained.id
    assert Conversations.get_rating(first, %{person_id: loser.id}).id == discarded.id

    assert {:ok, updated} =
             Conversations.rate_message_by_id(first.id, %{person_id: loser.id, rating: 2})

    assert updated.id == discarded.id
    assert Conversations.get_rating(first, %{person_id: survivor.id}).rating == 5
    assert {:ok, _} = People.merge_persons(survivor, loser)
    assert Repo.get(MessageRating, discarded.id) == nil
    assert Repo.get!(MessageRating, retained.id).rating == 5
    assert Repo.get!(MessageRating, transferred.id).person_id == survivor.id
    assert Conversations.get_person_conversation(conv.id, survivor.id)
  end

  test "Person author cannot coexist with BO or channel attribution" do
    refute MessageRating.changeset(%MessageRating{}, %{
             message_id: Ecto.UUID.generate(),
             person_id: 1,
             user_id: 2,
             rating: 5
           }).valid?

    refute MessageRating.changeset(%MessageRating{}, %{
             message_id: Ecto.UUID.generate(),
             person_id: 1,
             channel_user_id: "actor",
             rating: 5
           }).valid?
  end

  test "an enclosing rollback restores both rating owners and merge participants" do
    {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    {:ok, loser} = People.create_person(%{full_name: "Loser"})
    conv = conversation(loser.id, "active")
    {:ok, message} = Conversations.add_message(conv, %{role: "assistant", content: "Rating"})

    {:ok, rating} =
      Conversations.rate_message_by_id(message.id, %{person_id: loser.id, rating: 4})

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} = People.merge_persons(survivor, loser)
               Repo.rollback(:abort)
             end)

    assert People.get_person(loser.id).id == loser.id
    assert Repo.get!(MessageRating, rating.id).person_id == loser.id
    assert Conversations.get_person_conversation(conv.id, loser.id)
  end

  defp conversation(person_id, status) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        title: "History",
        channel_type: "api",
        person_id: person_id,
        status: status
      })

    conv
  end
end
