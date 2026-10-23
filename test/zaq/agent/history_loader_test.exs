defmodule Zaq.Agent.HistoryLoaderTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Accounts.Person
  alias Zaq.Agent.HistoryLoader
  alias Zaq.Agent.InputPrompt
  alias Zaq.Agent.OpaqueAliases
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Repo

  test "restored inputs use their directory author and original persisted source time" do
    person = insert_person()
    conversation = insert_conversation(person.id, "bo")

    message =
      %Message{conversation_id: conversation.id}
      |> Message.canonical_changeset(%{
        role: "user",
        content: "Persisted input",
        author_name: "Unverified channel name",
        history_context: %{"author_person_id" => person.id},
        provider_sent_at: ~U[2026-01-02 03:04:05Z]
      })
      |> Repo.insert!()

    [entry] = HistoryLoader.load_for_conversation(conversation.id).entries

    assert entry.content ==
             "Persisted input\n\n[Input context: #{Jason.encode!(person.full_name)}; person #{person.id}; sent 2026-01-02 03:04:05Z]"

    assert entry.timestamp == message.provider_sent_at
  end

  test "current and historical attachments share formatting without exposing hydration internals" do
    attachment = %{
      "id" => "file",
      "kind" => "file",
      "name" => "photo.png",
      "materialization_handle" => "fresh-handle",
      "content" => "private bytes",
      "raw" => %{"secret" => true},
      "attributes" => %{
        "materialization_source" => %{"locator" => %{"reference" => "provider-reference"}},
        "media_kind" => "image"
      }
    }

    message = %{
      message_id: Ecto.UUID.generate(),
      role: "external",
      content: nil,
      author_name: "Alice",
      author_id: "alice",
      provider_sent_at: nil,
      attachments: [attachment]
    }

    [entry] = HistoryLoader.from_projection([message]).entries

    assert entry.content ==
             InputPrompt.append_attachments(
               "",
               [attachment],
               nil
             ) <> "\n\n[Input context: \"Unknown author\"]"

    assert entry.content =~ "fresh-handle"
    assert entry.content =~ "media_kind"
    refute entry.content =~ "materialization_source"
    refute entry.content =~ "provider-reference"
    refute entry.content =~ "private bytes"
    refute entry.content =~ "secret"
  end

  property "canonical conversion never copies opaque private fields into model entries" do
    check all(
            content <- string(:alphanumeric, min_length: 1),
            private <- string(:alphanumeric, min_length: 1)
          ) do
      message = %{
        message_id: Ecto.UUID.generate(),
        role: "external",
        content: content,
        author_name: "Author",
        author_id: "source",
        provider_sent_at: nil,
        attachments: [],
        metadata: %{secret: private},
        trace: [%{content: private}],
        tool_results: [private]
      }

      [entry] = HistoryLoader.from_projection([message]).entries
      assert entry.content == "#{content}\n\n[Input context: \"Unknown author\"]"
      assert entry.refs == %{message_id: message.message_id}
      assert entry.tool_calls == nil
      assert entry.thinking == nil
    end
  end

  test "canonical projection conversion retains attribution and UUID references, not private fields" do
    id = Ecto.UUID.generate()
    transcript_id = Ecto.UUID.generate()

    context =
      HistoryLoader.from_projection([
        %{
          message_id: id,
          transcript_id: transcript_id,
          position: 2,
          role: "external",
          content: "Factual note",
          author_name: "Bob",
          author_id: "bob",
          provider_sent_at: nil,
          attachments: [],
          trace: [%{content: "PRIVATE_TRACE"}]
        }
      ])

    [entry] = context.entries
    assert entry.role == :user
    assert entry.content == "Factual note\n\n[Input context: \"Unknown author\"]"
    assert entry.refs == %{message_id: id, transcript_id: transcript_id, position: 2}
    refute inspect(context) =~ "PRIVATE_TRACE"
  end

  test "request-local cumulative merges preserve system, active tool pairs and steered identity" do
    transcript_id = Ecto.UUID.generate()
    historical = projection_message(transcript_id, "Old", 1)
    a = projection_message(transcript_id, "A", 2)
    b = projection_message(transcript_id, "B", 3)
    steering = projection_message(transcript_id, "Correction", 4)

    context =
      HistoryLoader.from_projection([historical])
      |> Map.put(:system_prompt, "System")
      |> AIContext.append_user("Question")
      |> AIContext.append_assistant("", [%{id: "call", name: "add", arguments: %{value: 2}}])
      |> AIContext.append_tool_result("call", "add", "Result")
      |> AIContext.append_user("Correction", refs: %{message_id: steering.message_id})

    first = HistoryLoader.merge_projection(context, [a, steering])
    second = HistoryLoader.merge_projection(context, [a, b, steering])
    [old | exchange] = Enum.reverse(context.entries)
    [^old, a_entry | ^exchange] = Enum.reverse(first.entries)
    [^old, ^a_entry, b_entry | ^exchange] = Enum.reverse(second.entries)
    assert a_entry.content == projected_content("A")
    assert b_entry.content == projected_content("B")
    assert second.system_prompt == context.system_prompt
    assert HistoryLoader.merge_projection(second, [a, b, steering]) == second

    assert Enum.map(context.entries, & &1.content) == [
             "Correction",
             "Result",
             "",
             "Question",
             projected_content("Old")
           ]
  end

  property "projection merges are UUID-idempotent and do not transfer tool authority" do
    check all(content <- string(:alphanumeric, min_length: 1), max_runs: 20) do
      message = projection_message(Ecto.UUID.generate(), content, 1)
      context = AIContext.new(system_prompt: "System") |> AIContext.append_user("Question")
      projected = HistoryLoader.merge_projection(context, [message, message])
      assert HistoryLoader.merge_projection(projected, [message]) == projected
      assert length(projected.entries) == 2
      assert List.first(projected.entries) == List.first(context.entries)
      assert projected.system_prompt == "System"
      assert Enum.all?(projected.entries, &is_nil(&1.tool_calls))
    end
  end

  test "completed exchanges stay before later associations and the next active tool sequence" do
    transcript = Ecto.UUID.generate()
    a = projection_message(transcript, "During run", 1)
    d = projection_message(transcript, "After completion", 2)
    answer_id = Ecto.UUID.generate()

    context =
      AIContext.new(system_prompt: "System")
      |> AIContext.append_user("Old question", refs: %{message_id: Ecto.UUID.generate()})
      |> AIContext.append_assistant("", [%{id: "old-call", name: "add", arguments: %{value: 2}}])
      |> AIContext.append_tool_result("old-call", "add", "Old result")
      |> AIContext.append_assistant("Old answer")
      |> HistoryLoader.bind_completed_answer(answer_id)
      |> HistoryLoader.complete_projection([a])

    assert hd(context.entries).refs.message_id == answer_id
    reconciled = HistoryLoader.bind_completed_answer(context, answer_id, "Persisted fallback")
    assert hd(reconciled.entries).content == "Persisted fallback"
    assert hd(reconciled.entries).refs == hd(context.entries).refs
    assert tl(reconciled.entries) == tl(context.entries)
    assert HistoryLoader.complete_projection(context, [a]) == context

    next =
      context
      |> AIContext.append_user("Next question")
      |> AIContext.append_assistant("", [%{id: "next-call", name: "add", arguments: %{value: 3}}])
      |> AIContext.append_tool_result("next-call", "add", "Next result")

    merged = HistoryLoader.merge_projection(next, [a, d])

    assert Enum.map(Enum.reverse(merged.entries), & &1.content) == [
             projected_content("During run"),
             "Old question",
             "",
             "Old result",
             "Old answer",
             projected_content("After completion"),
             "Next question",
             "",
             "Next result"
           ]

    assert merged.system_prompt == "System"
    assert HistoryLoader.merge_projection(merged, [a, d]) == merged
  end

  defp projection_message(transcript_id, content, position),
    do: %{
      message_id: Ecto.UUID.generate(),
      transcript_id: transcript_id,
      position: position,
      role: "external",
      content: content,
      author_name: "Author",
      author_id: "source",
      provider_sent_at: ~U[2026-10-08 00:00:00Z],
      attachments: []
    }

  defp projected_content(body),
    do: "#{body}\n\n[Input context: \"Unknown author\"; sent 2026-10-08 00:00:00Z]"

  defp insert_person do
    Repo.insert!(%Person{
      full_name: "Test Person #{System.unique_integer([:positive])}",
      status: "active"
    })
  end

  defp insert_conversation(person_id, channel_type, attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(
      Map.merge(
        %{
          channel_user_id: "user_#{System.unique_integer([:positive])}",
          channel_type: channel_type,
          person_id: person_id,
          status: "active"
        },
        attrs
      )
    )
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
    [metadata | _annotation] = String.split(encoded, "\n\n[Input context:", parts: 2)
    Jason.decode!(metadata)
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
      assert String.starts_with?(hd(messages).content, "from conv A\n\n[Input context:")
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
      assert String.starts_with?(m1.content, "first\n\n[Input context:")
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
      assert String.starts_with?(hd(messages).content, "valid context\n\n[Input context:")
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

    test "loads only the explicitly bound conversation" do
      person = insert_person()

      matching =
        insert_conversation(person.id, "mattermost", %{
          channel_config_id: nil,
          external_channel_id: "room-1",
          external_thread_id: "thread-1",
          channel_user_id: "transport-user"
        })

      other_thread =
        insert_conversation(person.id, "mattermost", %{
          external_channel_id: "room-1",
          external_thread_id: "thread-2",
          channel_user_id: "transport-user"
        })

      channel_level =
        insert_conversation(person.id, "mattermost", %{
          external_channel_id: "room-1",
          external_thread_id: nil,
          channel_user_id: "transport-user"
        })

      other_participant =
        insert_conversation(person.id, "mattermost", %{
          external_channel_id: "room-1",
          external_thread_id: "thread-1",
          channel_user_id: "other-transport-user"
        })

      legacy = insert_conversation(person.id, "mattermost")

      insert_message(matching, "user", "matching thread")
      insert_message(other_thread, "user", "other thread")
      insert_message(channel_level, "user", "channel level")
      insert_message(other_participant, "user", "other transport participant")
      insert_message(legacy, "user", "legacy mixed history")

      result =
        HistoryLoader.load_context(%{
          conversation_id: matching.id
        })

      assert [message] = AIContext.to_messages(result)
      assert String.starts_with?(message.content, "matching thread\n\n[Input context:")
    end

    test "loads an explicitly bound conversation without a Person" do
      conversation =
        insert_conversation(nil, "discord", %{
          external_channel_id: "room-1",
          external_thread_id: nil,
          channel_user_id: "discord-user"
        })

      insert_message(conversation, "assistant", "same participant and room")

      result =
        HistoryLoader.load_context(%{
          conversation_id: conversation.id
        })

      expected = "same participant and room"
      assert [%{content: ^expected}] = AIContext.to_messages(result)
    end

    test "does not hydrate pending or failed admitted messages" do
      conversation = insert_conversation(nil, "discord")
      insert_message(conversation, "user", "completed", nil, %{"execution_status" => "completed"})
      insert_message(conversation, "user", "pending", nil, %{"execution_status" => "pending"})
      insert_message(conversation, "user", "failed", nil, %{"execution_status" => "failed"})

      result = HistoryLoader.load_context(%{conversation_id: conversation.id})

      assert [message] = AIContext.to_messages(result)
      assert String.starts_with?(message.content, "completed\n\n[Input context:")
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
      assert String.starts_with?(hd(messages).content, "hello from user\n\n[Input context:")
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
      assert String.starts_with?(m1.content, "first\n\n[Input context:")
      assert m2.content == "second"
      assert String.starts_with?(m3.content, "third\n\n[Input context:")
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
