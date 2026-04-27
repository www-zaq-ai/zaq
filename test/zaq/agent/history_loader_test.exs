defmodule Zaq.Agent.HistoryLoaderTest do
  use Zaq.DataCase, async: true

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Accounts.Person
  alias Zaq.Agent.HistoryLoader
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Repo

  defp insert_person do
    Repo.insert!(%Person{
      full_name: "Test Person #{System.unique_integer([:positive])}",
      status: "active"
    })
  end

  defp insert_conversation(person_id, channel_type) do
    %Conversation{}
    |> Conversation.changeset(%{
      channel_user_id: "user_#{System.unique_integer([:positive])}",
      channel_type: channel_type,
      person_id: person_id,
      status: "active"
    })
    |> Repo.insert!()
  end

  defp insert_message(conversation, role, content, inserted_at \\ nil) do
    attrs = %{
      conversation_id: conversation.id,
      role: role,
      content: content,
      inserted_at: inserted_at || DateTime.utc_now()
    }

    Repo.insert!(struct(Message, attrs))
  end

  describe "load/3" do
    test "returns empty context when no conversations exist for that person" do
      person = insert_person()
      result = HistoryLoader.load(person.id, "mattermost")
      assert %AIContext{} = result
      assert AIContext.empty?(result)
    end

    test "returns empty context for nil person_id" do
      result = HistoryLoader.load(nil, "mattermost")
      assert %AIContext{} = result
      assert AIContext.empty?(result)
    end

    test "maps user DB role to user entry" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")
      insert_message(conv, "user", "hello from user")

      result = HistoryLoader.load(person.id, "mattermost")

      messages = AIContext.to_messages(result)
      assert length(messages) == 1
      assert hd(messages).role == :user
      assert hd(messages).content == "hello from user"
    end

    test "maps assistant DB role to assistant entry" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")
      insert_message(conv, "assistant", "hello from bot")

      result = HistoryLoader.load(person.id, "mattermost")

      messages = AIContext.to_messages(result)
      assert length(messages) == 1
      assert hd(messages).role == :assistant
      assert hd(messages).content == "hello from bot"
    end

    test "to_messages returns entries in chronological order" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")
      t1 = ~U[2026-04-01 10:00:00.000000Z]
      t2 = ~U[2026-04-01 10:01:00.000000Z]
      t3 = ~U[2026-04-01 10:02:00.000000Z]

      insert_message(conv, "user", "first", t1)
      insert_message(conv, "assistant", "second", t2)
      insert_message(conv, "user", "third", t3)

      result = HistoryLoader.load(person.id, "mattermost")
      messages = AIContext.to_messages(result)

      assert length(messages) == 3
      contents = Enum.map(messages, & &1.content)
      assert contents == ["first", "second", "third"]
    end

    test "truncates to stay within max_tokens (keeps most recent)" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")
      # ~10 words × 1.3 ≈ 13 tokens per message; max_tokens: 15 → only 1 fits
      insert_message(
        conv,
        "user",
        "one two three four five six seven eight nine ten",
        ~U[2026-04-01 10:00:00.000000Z]
      )

      insert_message(
        conv,
        "assistant",
        "one two three four five six seven eight nine ten",
        ~U[2026-04-01 10:01:00.000000Z]
      )

      result = HistoryLoader.load(person.id, "mattermost", max_tokens: 15)
      messages = AIContext.to_messages(result)

      assert length(messages) == 1
      assert hd(messages).role == :assistant
    end

    test "uses default 5000 tokens when max_tokens not supplied" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")
      insert_message(conv, "user", "short message")

      result = HistoryLoader.load(person.id, "mattermost")
      messages = AIContext.to_messages(result)
      assert length(messages) == 1
    end

    test "only loads conversations matching channel_type" do
      person = insert_person()
      conv_mm = insert_conversation(person.id, "mattermost")
      _conv_bo = insert_conversation(person.id, "bo")

      insert_message(conv_mm, "user", "mattermost msg")

      result = HistoryLoader.load(person.id, "bo")
      assert AIContext.empty?(result)
    end

    test "returns empty context when channel_type is nil" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")
      insert_message(conv, "user", "some message")

      result = HistoryLoader.load(person.id, nil)
      assert %AIContext{} = result
      assert AIContext.empty?(result)
    end

    test "fetch is bounded to 500 rows from the DB" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")

      for i <- 1..510 do
        insert_message(conv, "user", "message #{i}")
      end

      # Use a high token budget so only the DB limit applies, not the token budget.
      result = HistoryLoader.load(person.id, "mattermost", max_tokens: 1_000_000)
      messages = AIContext.to_messages(result)
      assert length(messages) <= 500
    end
  end
end
