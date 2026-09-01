defmodule Zaq.Agent.HistoryLoaderTest do
  use Zaq.DataCase, async: false

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Accounts.Person
  alias Zaq.Agent.HistoryLoader
  alias Zaq.Agent.OpaqueAliases
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

  defp insert_message(conversation, role, content, inserted_at \\ nil, metadata \\ %{}) do
    attrs = %{
      conversation_id: conversation.id,
      role: role,
      content: content,
      inserted_at: inserted_at || DateTime.utc_now(),
      metadata: metadata
    }

    Repo.insert!(struct(Message, attrs))
  end

  defp rendered_attachments(message) do
    [_content, encoded] = String.split(message.content, "Attachments:\n", parts: 2)
    Jason.decode!(encoded)
  end

  defp restore_runtime_store(name, pid) do
    if Process.whereis(name) == nil and Process.alive?(pid) do
      Process.register(pid, name)
    end
  end

  defp with_runtime_store_unregistered(fun) do
    name = Jido.runtime_store_name(Zaq.Agent.Jido)
    pid = Process.whereis(name)
    assert is_pid(pid)
    Process.unregister(name)
    on_exit(fn -> restore_runtime_store(name, pid) end)

    try do
      fun.()
    after
      restore_runtime_store(name, pid)
    end
  end

  describe "load_for_conversation/2" do
    test "returns empty context for nil conversation_id" do
      result = HistoryLoader.load_for_conversation(nil)
      assert %AIContext{} = result
      assert AIContext.empty?(result)
    end

    test "returns empty context for empty string conversation_id" do
      result = HistoryLoader.load_for_conversation("")
      assert %AIContext{} = result
      assert AIContext.empty?(result)
    end

    test "returns only messages from the given conversation" do
      person = insert_person()
      conv_a = insert_conversation(person.id, "bo")
      conv_b = insert_conversation(person.id, "bo")
      insert_message(conv_a, "user", "from conv A")
      insert_message(conv_b, "user", "from conv B")

      result = HistoryLoader.load_for_conversation(conv_a.id)
      messages = AIContext.to_messages(result)

      assert length(messages) == 1
      assert String.ends_with?(hd(messages).content, "from conv A")
    end

    test "does not include messages from other conversations" do
      person = insert_person()
      conv_a = insert_conversation(person.id, "bo")
      conv_b = insert_conversation(person.id, "bo")
      insert_message(conv_b, "user", "should not appear")

      result = HistoryLoader.load_for_conversation(conv_a.id)
      assert AIContext.empty?(result)
    end

    test "returns messages in chronological order" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")
      t1 = ~U[2026-04-01 10:00:00.000000Z]
      t2 = ~U[2026-04-01 10:01:00.000000Z]
      insert_message(conv, "user", "first", t1)
      insert_message(conv, "assistant", "second", t2)

      result = HistoryLoader.load_for_conversation(conv.id)
      messages = AIContext.to_messages(result)

      assert length(messages) == 2
      [m1, m2] = messages
      assert String.ends_with?(m1.content, "first")
      assert m2.content == "second"
    end

    test "loads all fetched conversation messages without token trimming" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")

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

      result = HistoryLoader.load_for_conversation(conv.id)
      messages = AIContext.to_messages(result)

      assert length(messages) == 2
      assert Enum.map(messages, & &1.role) == [:user, :assistant]
    end

    test "includes safe attachment descriptors without loading media bytes" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")

      insert_message(conv, "user", "", nil, %{
        "attachments" => [
          %{
            "id" => "file-1",
            "kind" => "file",
            "name" => "photo.png",
            "mime_type" => "image/png",
            "attributes" => %{
              "source_type" => "communication_media",
              "provider" => "mattermost",
              "source_id" => "file-1"
            }
          }
        ]
      })

      [message] =
        conv.id
        |> HistoryLoader.load_for_conversation()
        |> AIContext.to_messages()

      assert message.content =~ "Attachments:"
      assert message.content =~ "photo.png"
      assert message.content =~ "file-1"
      refute message.content =~ "materializing_event"
    end

    test "ignores unsupported persisted message roles" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")
      insert_message(conv, "system", "should not appear", ~U[2026-04-01 10:00:00.000000Z])
      insert_message(conv, "user", "valid context", ~U[2026-04-01 10:01:00.000000Z])

      messages = conv.id |> HistoryLoader.load_for_conversation() |> AIContext.to_messages()

      assert length(messages) == 1
      assert String.ends_with?(hd(messages).content, "valid context")
    end

    test "ignores a non-list attachments value" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")
      insert_message(conv, "user", "plain context", nil, %{"attachments" => "not-a-list"})

      [message] = conv.id |> HistoryLoader.load_for_conversation() |> AIContext.to_messages()

      assert message.content =~ "plain context"
      refute message.content =~ "Attachments:\n"
    end

    test "handles nil message metadata as having no attachments" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")
      insert_message(conv, "user", "preserved context", nil, nil)

      [message] = conv.id |> HistoryLoader.load_for_conversation() |> AIContext.to_messages()

      assert message.content =~ "preserved context"
      refute message.content =~ "Attachments:\n"
    end

    test "aliases attachment materialization handles for scoped history" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")
      scope = "history-scope-#{System.unique_integer([:positive])}"
      canonical = "signed-materialization-handle"

      OpaqueAliases.clear_scope(scope)
      on_exit(fn -> OpaqueAliases.clear_scope(scope) end)

      insert_message(conv, "user", "history", nil, %{
        "attachments" => [
          %{
            "materialization_handle" => canonical,
            "name" => "photo.png",
            "content" => "payload",
            "raw" => "raw-payload"
          }
        ]
      })

      [message] =
        conv.id
        |> HistoryLoader.load_for_conversation(opaque_alias_scope: scope)
        |> AIContext.to_messages()

      [attachment] = rendered_attachments(message)
      assert String.starts_with?(attachment["materialization_handle"], "mat_")
      refute attachment["materialization_handle"] == canonical
      assert attachment["name"] == "photo.png"
      refute Map.has_key?(attachment, "content")
      refute Map.has_key?(attachment, "raw")
      refute message.content =~ canonical
      refute message.content =~ "payload"
    end

    test "retains the safe canonical descriptor when alias storage is unavailable" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")
      scope = "unavailable-history-scope-#{System.unique_integer([:positive])}"
      canonical = "signed-materialization-handle"

      insert_message(conv, "user", "history", nil, %{
        "attachments" => [
          %{
            "materialization_handle" => canonical,
            "name" => "photo.png",
            "content" => "payload",
            "raw" => "raw-payload"
          }
        ]
      })

      with_runtime_store_unregistered(fn ->
        [message] =
          conv.id
          |> HistoryLoader.load_for_conversation(opaque_alias_scope: scope)
          |> AIContext.to_messages()

        [attachment] = rendered_attachments(message)
        assert attachment["materialization_handle"] == canonical
        assert attachment["name"] == "photo.png"
        refute Map.has_key?(attachment, "content")
        refute Map.has_key?(attachment, "raw")
        refute message.content =~ "payload"
      end)
    end

    test "is bounded to 500 rows from the DB" do
      person = insert_person()
      conv = insert_conversation(person.id, "bo")

      for i <- 1..510 do
        insert_message(conv, "user", "message #{i}")
      end

      result = HistoryLoader.load_for_conversation(conv.id)
      messages = AIContext.to_messages(result)
      assert length(messages) <= 500
    end
  end

  describe "load_context/2" do
    test "returns empty context when spawn opts are nil" do
      result = HistoryLoader.load_context(%{})
      assert %AIContext{} = result
      assert AIContext.empty?(result)
    end
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
      # User messages are prefixed with a timestamp so the LLM can answer timing questions
      assert String.ends_with?(hd(messages).content, "hello from user")
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
      [m1, m2, m3] = messages
      # User messages carry a timestamp prefix; assistant messages do not
      assert String.ends_with?(m1.content, "first")
      assert m2.content == "second"
      assert String.ends_with?(m3.content, "third")
    end

    test "loads all fetched person/provider messages without token trimming" do
      person = insert_person()
      conv = insert_conversation(person.id, "mattermost")

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

      result = HistoryLoader.load(person.id, "mattermost")
      messages = AIContext.to_messages(result)

      assert length(messages) == 2
      assert Enum.map(messages, & &1.role) == [:user, :assistant]
    end

    test "loads matching history when no optional arguments are supplied" do
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

      result = HistoryLoader.load(person.id, "mattermost")
      messages = AIContext.to_messages(result)
      assert length(messages) <= 500
    end
  end
end
