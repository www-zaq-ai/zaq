defmodule Zaq.Engine.Conversations.CanonicalStorageTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations

  alias Zaq.Engine.Conversations.{
    Message,
    MessageRating,
    MessageTraceArtifact,
    Transcript,
    TranscriptMessage
  }

  defp canonical_message(attrs \\ %{}) do
    %Message{}
    |> Message.canonical_changeset(
      Map.merge(
        %{
          role: "external",
          content: "Provider announcement",
          source_provider: "mattermost",
          source_account_key: "connector:12",
          external_message_id: "post-1",
          author_id: "provider-user-1",
          author_name: "Alice",
          provider_sent_at: ~U[2026-09-26 10:00:00Z],
          attachments: [%{"id" => "attachment-1"}]
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp transcript(scope_key, attrs \\ %{}) do
    %Transcript{}
    |> Transcript.changeset(
      Map.merge(
        %{
          strategy: "shared",
          provider: "mattermost",
          scope_key: scope_key,
          external_channel_id: "room-1",
          permission_resource_type: "channel_history",
          permission_resource_id: Jason.encode!(["mattermost", 12, "room-1"])
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp attach(transcript, message, position) do
    %TranscriptMessage{}
    |> TranscriptMessage.changeset(%{
      transcript_id: transcript.id,
      message_id: message.id,
      position: position,
      provenance: "provider_event"
    })
    |> Repo.insert!()
  end

  test "one canonical message belongs to multiple transcripts without duplicating its identity" do
    message = canonical_message()
    channel = transcript("channel:12:room-1")

    thread =
      transcript("thread:12:room-1:thread-1", %{
        parent_id: channel.id,
        external_thread_id: "thread-1"
      })

    first = attach(channel, message, 1)
    second = attach(thread, message, 7)

    assert message.conversation_id == nil
    assert first.message_id == second.message_id
    assert first.transcript_id != second.transcript_id
    assert second.position == 7
    assert Repo.get!(Message, message.id).attachments == [%{"id" => "attachment-1"}]
    assert Repo.get!(Transcript, thread.id).parent_id == channel.id
    assert Repo.aggregate(from(m in Message, where: m.id == ^message.id), :count) == 1
  end

  test "legacy conversation messages and dependent rows retain their original IDs" do
    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "bo", channel_user_id: "legacy-1"})

    {:ok, message} = Conversations.add_message(conversation, %{role: "user", content: "Existing"})

    rating =
      %MessageRating{}
      |> MessageRating.changeset(%{
        message_id: message.id,
        channel_user_id: "legacy-1",
        rating: 5
      })
      |> Repo.insert!()

    artifact =
      %MessageTraceArtifact{message_id: message.id}
      |> MessageTraceArtifact.changeset(
        %{
          tool_call_id: "tool-1",
          tool_name: "fixture",
          name: "result",
          mime_type: "text/plain",
          size: 3,
          sha256: :crypto.hash(:sha256, "abc"),
          content: "abc"
        },
        1024
      )
      |> Repo.insert!()

    assert [%Message{id: id, content: "Existing"}] = Conversations.list_messages(conversation)
    assert id == message.id

    transcript = transcript("legacy:#{conversation.id}", %{conversation_id: conversation.id})
    association = attach(transcript, message, 1)

    assert Repo.get!(Message, id).conversation_id == conversation.id
    assert Repo.get!(TranscriptMessage, association.id).message_id == id
    assert Repo.get!(MessageRating, rating.id).message_id == id
    assert Repo.get!(MessageTraceArtifact, artifact.id).message_id == id
    assert [%Message{id: ^id}] = Conversations.list_messages(conversation)
  end

  test "source identity and transcript associations are unique within their own scope" do
    message = canonical_message()

    assert {:error, changeset} =
             %Message{}
             |> Message.canonical_changeset(%{
               role: "external",
               content: "Duplicate",
               source_provider: message.source_provider,
               source_account_key: message.source_account_key,
               external_message_id: message.external_message_id
             })
             |> Repo.insert()

    assert %{external_message_id: _} = errors_on(changeset)

    other_account = canonical_message(%{source_account_key: "connector:13"})
    assert other_account.id != message.id

    channel = transcript("channel:12:room-1")
    attach(channel, message, 1)

    assert {:error, duplicate_message} =
             %TranscriptMessage{}
             |> TranscriptMessage.changeset(%{
               transcript_id: channel.id,
               message_id: message.id,
               position: 2,
               provenance: "replay"
             })
             |> Repo.insert()

    assert %{message_id: _} = errors_on(duplicate_message)

    assert {:error, duplicate_position} =
             %TranscriptMessage{}
             |> TranscriptMessage.changeset(%{
               transcript_id: channel.id,
               message_id: other_account.id,
               position: 1,
               provenance: "provider_event"
             })
             |> Repo.insert()

    assert %{position: _} = errors_on(duplicate_position)
  end

  test "duplicate transcript scopes and nonexistent parent references fail closed" do
    transcript("same-scope")

    assert {:error, duplicate_scope} =
             %Transcript{}
             |> Transcript.changeset(%{
               strategy: "shared",
               provider: "mattermost",
               scope_key: "same-scope",
               permission_resource_type: "channel_history",
               permission_resource_id: Jason.encode!(["mattermost", 12, "room-1"])
             })
             |> Repo.insert()

    assert %{scope_key: _} = errors_on(duplicate_scope)

    assert {:error, missing_parent} =
             %Transcript{}
             |> Transcript.changeset(%{
               strategy: "shared",
               provider: "mattermost",
               scope_key: "thread-without-parent",
               parent_id: Ecto.UUID.generate(),
               permission_resource_type: "channel_history",
               permission_resource_id: Jason.encode!(["mattermost", 12, "room-1"])
             })
             |> Repo.insert()

    assert %{parent_id: _} = errors_on(missing_parent)
  end

  test "direct and replicated transcript ownership is an explicit Person reference" do
    {:ok, owner} = People.create_person(%{"full_name" => "History Owner"})

    for strategy <- ["direct", "replicated"] do
      assert %{owner_person_id: _} =
               %Transcript{}
               |> Transcript.changeset(%{
                 strategy: strategy,
                 provider: "mattermost",
                 scope_key: "#{strategy}:missing-owner",
                 permission_resource_type: "person_history",
                 permission_resource_id: "owner:#{owner.id}"
               })
               |> errors_on()

      owned =
        transcript("#{strategy}:#{owner.id}", %{
          strategy: strategy,
          owner_person_id: owner.id,
          permission_resource_type: "person_history",
          permission_resource_id: "owner:#{owner.id}"
        })

      assert Repo.get!(Transcript, owned.id).owner_person_id == owner.id
    end

    assert %{owner_person_id: _} =
             %Transcript{}
             |> Transcript.changeset(%{
               strategy: "shared",
               provider: "mattermost",
               owner_person_id: owner.id,
               scope_key: "shared:owner-not-allowed",
               permission_resource_type: "channel_history",
               permission_resource_id: "room-1"
             })
             |> errors_on()

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn ->
        Repo.insert!(%Transcript{
          strategy: "direct",
          provider: "mattermost",
          scope_key: "unowned-direct-raw",
          permission_resource_type: "person_history",
          permission_resource_id: "owner:#{owner.id}"
        })
      end)
    end
  end

  test "source identity cannot be partially specified or attached at an invalid position" do
    assert %{source_account_key: _} =
             %Message{}
             |> Message.canonical_changeset(%{
               role: "external",
               content: "Incomplete",
               source_provider: "mattermost",
               external_message_id: "post-2"
             })
             |> errors_on()

    channel = transcript("channel:12:room-1")
    message = canonical_message()

    assert %{position: _} =
             %TranscriptMessage{}
             |> TranscriptMessage.changeset(%{
               transcript_id: channel.id,
               message_id: message.id,
               position: 0,
               provenance: "provider_event"
             })
             |> errors_on()
  end

  test "canonical source identity cannot be reassigned after insertion" do
    message = canonical_message()

    assert %{external_message_id: _} =
             message
             |> Message.canonical_changeset(%{external_message_id: "different-provider-post"})
             |> errors_on()

    assert %{source_account_key: _} =
             message
             |> Message.canonical_changeset(%{source_account_key: "connector:99"})
             |> errors_on()

    assert %{external_message_id: _} =
             message
             |> Message.canonical_changeset(%{external_message_id: nil})
             |> errors_on()

    assert {:ok, updated} =
             message
             |> Message.canonical_changeset(%{author_name: "Alice Changed"})
             |> Repo.update()

    assert updated.external_message_id == message.external_message_id
    assert updated.author_name == "Alice Changed"
  end

  test "external messages may contain attachments instead of text" do
    message = canonical_message(%{content: "", attachments: [%{"id" => "picture-1"}]})
    assert message.content == ""
    assert message.attachments == [%{"id" => "picture-1"}]

    assistant =
      canonical_message(%{
        role: "assistant",
        content: "",
        external_message_id: "bot-post-1",
        attachments: [%{"id" => "chart-1"}]
      })

    assert assistant.content == ""
    assert assistant.attachments == [%{"id" => "chart-1"}]

    assert %{content: _} =
             %Message{}
             |> Message.canonical_changeset(%{role: "external", content: "", attachments: nil})
             |> errors_on()
  end

  test "the database rejects a partial source identity even without the canonical changeset" do
    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn ->
        Repo.insert!(%Message{
          role: "external",
          content: "Not a complete source",
          source_provider: "mattermost"
        })
      end)
    end
  end

  property "identical provider message IDs in different accounts stay distinct" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 18), max_runs: 16) do
      scope = System.unique_integer([:positive])

      first =
        canonical_message(%{external_message_id: id, source_account_key: "connector:#{scope}:a"})

      second =
        canonical_message(%{external_message_id: id, source_account_key: "connector:#{scope}:b"})

      assert first.id != second.id
      assert first.external_message_id == second.external_message_id
    end
  end
end
