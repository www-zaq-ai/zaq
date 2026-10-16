defmodule Zaq.Engine.Conversations.MessageAuthorTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations.MessageAuthor
  alias Zaq.QueryRecorder

  test "one directory query attributes the whole batch without changing message content" do
    {:ok, alice} = People.create_person(%{full_name: "Alice"})
    {:ok, bob} = People.create_person(%{full_name: "Bob"})

    messages = Enum.map([alice, bob, alice], &message(&1.id))
    {projected, queries} = QueryRecorder.capture(fn -> MessageAuthor.project(messages) end)
    assert Enum.count(queries, &(&1.source == "people")) == 1
    assert Enum.map(projected, & &1.author.name) == ["Alice", "Bob", "Alice"]
    assert Enum.map(projected, &Map.drop(&1, [:author, :timestamp])) == messages
  end

  test "merged references retain recorded identity but resolve the current directory name" do
    {:ok, original} = People.create_person(%{full_name: "Original"})
    {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    assert {:ok, _} = People.merge_persons(survivor, original)
    survivor = People.get_person!(survivor.id)
    assert {:ok, _} = People.update_person(survivor, %{full_name: "Renamed"})

    assert [projected] = MessageAuthor.project([message(original.id)])
    assert projected.author == %{kind: :person, person_id: original.id, name: "Renamed"}
  end

  test "missing directory entries never use a channel display name or conversation owner" do
    {:ok, owner} = People.create_person(%{full_name: "Owner"})

    messages = [
      Map.merge(message(nil), %{person_id: owner.id, author_name: "Unverified name"}),
      message(owner.id + 1)
    ]

    assert [unknown, removed] = MessageAuthor.project(messages)
    assert unknown.author == %{kind: :unknown, person_id: nil, name: "Unknown author"}
    assert removed.author.name == "Unknown author"
    assert removed.author.person_id == owner.id + 1
  end

  test "nonhuman roles use agent or tool identity without resolving a requester as their author" do
    messages = [
      %{role: "assistant", metadata: %{"agent" => %{"name" => "Invoice agent"}}},
      %{role: :assistant},
      %{role: :system},
      %{role: :tool, name: "accounts.fetch_history", tool_call_id: "call-1"},
      %{role: "tool"}
    ]

    {projected, queries} = QueryRecorder.capture(fn -> MessageAuthor.project(messages) end)
    assert queries == []

    assert Enum.map(projected, & &1.author.name) == [
             "Invoice agent",
             "Assistant",
             "System",
             "accounts.fetch_history",
             "Tool"
           ]

    assert Enum.at(projected, 3).tool_call_id == "call-1"
  end

  test "blank directory names and invalid author references have explicit fallbacks" do
    blank = Repo.insert!(%Zaq.Accounts.Person{full_name: "  "})
    assert [projected] = MessageAuthor.project([message(blank.id)])
    assert projected.author.name == "Unknown author"

    messages = Enum.map([nil, -1, 0, "123", 9_223_372_036_854_775_808], &message/1)
    {projected, queries} = QueryRecorder.capture(fn -> MessageAuthor.project(messages) end)
    assert queries == []
    assert Enum.all?(projected, &(&1.author.person_id == nil))
  end

  test "the directory batch lookup returns only requested IDs, with aliases pointing to survivors" do
    {:ok, original} = People.create_person(%{full_name: "Original"})
    {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    assert {:ok, _} = People.merge_persons(survivor, original)

    {people, queries} =
      QueryRecorder.capture(fn -> People.get_people_by_ids([original.id, original.id, nil]) end)

    assert Map.keys(people) == [original.id]
    assert people[original.id].id == survivor.id
    assert Enum.count(queries, &(&1.source == "people")) == 1
  end

  property "attribution follows message identity under repeated and reordered authors" do
    {:ok, alice} = People.create_person(%{full_name: "Same name"})
    {:ok, bob} = People.create_person(%{full_name: "Same name"})

    check all(ids <- list_of(member_of([alice.id, bob.id]), max_length: 30)) do
      messages =
        Enum.with_index(ids, fn id, index -> Map.put(message(id), :content, "#{index}") end)

      projected = MessageAuthor.project(messages)
      assert Enum.map(projected, & &1.author.person_id) == ids
      assert Enum.map(projected, & &1.content) == Enum.map(messages, & &1.content)
      assert Enum.all?(projected, &(&1.author.name == "Same name"))
    end
  end

  test "an empty batch does not query the directory" do
    assert {[], []} = QueryRecorder.capture(fn -> MessageAuthor.project([]) end)
  end

  defp message(id) do
    %{role: "user", content: "Body", history_context: %{"author_person_id" => id}}
  end
end
