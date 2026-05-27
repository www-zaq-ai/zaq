defmodule Zaq.Agent.Tools.Accounts.HistoryTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.Accounts.History
  alias Zaq.Engine.Conversations

  @ctx %{}

  defp create_person(email) do
    {:ok, person} = People.create_person(%{full_name: "Test Person", email: email})
    person
  end

  defp create_conversation(person_id) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "u_#{System.unique_integer([:positive])}",
        person_id: person_id
      })

    conv
  end

  defp add_messages(conv, count) do
    for i <- 1..count do
      {:ok, _} = Conversations.add_message(conv, %{role: "user", content: "Message #{i}"})
    end
  end

  describe "run/2 — no person_id" do
    test "returns empty history when person_id is nil" do
      assert {:ok, %{history: []}} = History.run(%{person_id: nil}, @ctx)
    end

    test "returns empty history when person_id is absent" do
      assert {:ok, %{history: []}} = History.run(%{}, @ctx)
    end
  end

  describe "run/2 — person with no conversations" do
    test "returns empty history" do
      person = create_person("noconv@example.com")
      assert {:ok, %{history: []}} = History.run(%{person_id: person.id}, @ctx)
    end
  end

  describe "run/2 — person with conversations" do
    test "returns messages from all conversations" do
      person = create_person("withmessages@example.com")
      conv1 = create_conversation(person.id)
      conv2 = create_conversation(person.id)
      add_messages(conv1, 2)
      add_messages(conv2, 3)

      assert {:ok, %{history: history}} = History.run(%{person_id: person.id}, @ctx)
      assert length(history) == 5
    end

    test "accepts string person_id" do
      person = create_person("strpid@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 2)

      assert {:ok, %{history: history}} =
               History.run(%{person_id: to_string(person.id)}, @ctx)

      assert length(history) == 2
    end
  end

  describe "run/2 — conversation_limit" do
    test "limits number of conversations fetched" do
      person = create_person("convlimit@example.com")

      for _ <- 1..5 do
        conv = create_conversation(person.id)
        add_messages(conv, 2)
      end

      assert {:ok, %{history: history}} =
               History.run(%{person_id: person.id, conversation_limit: 2}, @ctx)

      assert length(history) == 4
    end

    test "default conversation_limit is 10" do
      person = create_person("default_conv@example.com")

      for _ <- 1..12 do
        conv = create_conversation(person.id)
        add_messages(conv, 1)
      end

      assert {:ok, %{history: history}} = History.run(%{person_id: person.id}, @ctx)
      assert length(history) == 10
    end
  end

  describe "run/2 — error handling" do
    test "returns empty history when DB query raises" do
      # Passing an invalid person_id type causes Ecto to raise a CastError
      assert {:ok, %{history: []}} = History.run(%{person_id: %{invalid: true}}, @ctx)
    end
  end

  describe "run/2 — messages_per_conversation" do
    test "limits messages per conversation" do
      person = create_person("msglimit@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 20)

      assert {:ok, %{history: history}} =
               History.run(
                 %{person_id: person.id, messages_per_conversation: 5},
                 @ctx
               )

      assert length(history) == 5
    end

    test "default messages_per_conversation is 50" do
      person = create_person("default_msg@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 60)

      assert {:ok, %{history: history}} = History.run(%{person_id: person.id}, @ctx)
      assert length(history) == 50
    end

    test "applies limit per conversation independently" do
      person = create_person("perconv@example.com")
      conv1 = create_conversation(person.id)
      conv2 = create_conversation(person.id)
      add_messages(conv1, 10)
      add_messages(conv2, 10)

      assert {:ok, %{history: history}} =
               History.run(
                 %{person_id: person.id, messages_per_conversation: 3},
                 @ctx
               )

      assert length(history) == 6
    end
  end
end
