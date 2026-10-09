defmodule Zaq.Engine.Conversations.TranscriptHistoryTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations

  alias Zaq.Engine.Conversations.{
    Conversation,
    Message,
    Transcript,
    TranscriptHistory,
    TranscriptMessage
  }

  alias Zaq.Engine.History.Facts
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  defp person(name) do
    {:ok, person} = People.create_person(%{"full_name" => name})
    person
  end

  defp config do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "History #{System.unique_integer([:positive])}",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://example.invalid",
      token: "fixture-token"
    })
    |> Repo.insert!()
  end

  defp transcript(config, scope, attrs \\ %{}) do
    {resource_type, resource_id} = ChannelHistoryResource.for("mattermost", config.id, "room-1")

    %Transcript{}
    |> Transcript.changeset(
      Map.merge(
        %{
          strategy: "shared",
          provider: "mattermost",
          channel_config_id: config.id,
          external_channel_id: "room-1",
          scope_key: scope,
          permission_resource_type: resource_type,
          permission_resource_id: resource_id
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp source(config, overrides) do
    Map.merge(
      %{provider: "mattermost", channel_config_id: config.id, provenance: "provider_event"},
      overrides
    )
  end

  defp append(transcript, config, id, overrides \\ %{}, source_overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          role: "external",
          content: "message #{id}",
          external_message_id: id,
          author_id: "author-1",
          author_name: "Alice",
          attachments: [%{"id" => "a-1", "content" => "private attachment bytes"}]
        },
        overrides
      )

    Conversations.append_canonical_message(transcript.id, attrs, source(config, source_overrides))
  end

  defp legacy_conversation(config, external_channel_id \\ "room-1") do
    %Conversation{}
    |> Conversation.changeset(%{
      channel_type: "mattermost",
      channel_config_id: if(config, do: config.id),
      external_channel_id: external_channel_id
    })
    |> Repo.insert!()
  end

  defp legacy_user_message(conversation, external_id, content \\ "legacy content") do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation.id,
      role: "user",
      content: content,
      author_id: "legacy-author",
      metadata: %{"external_message_id" => external_id}
    })
    |> Repo.insert!()
  end

  test "recipient fan-out resolves one canonical message and connector per capture" do
    config = config()
    sender = person("Sender")
    recipients = Enum.map(1..4, &person("Recipient #{&1}"))

    {:ok, facts} =
      Facts.new(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: "room-1",
        kind: :replicated,
        actor_person_id: sender.id,
        recipient_person_ids: Enum.map(recipients, & &1.id)
      })

    attrs = %{
      role: "external",
      content: "shared content",
      external_message_id: "fan-out",
      author_id: "sender"
    }

    source = source(config, %{source_scope: "mailbox"})

    {{:ok, captured}, queries} =
      Zaq.QueryRecorder.capture(fn ->
        Conversations.capture_canonical_message(facts, attrs, source)
      end)

    assert map_size(captured.transcript_ids) == 5
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 5
    assert Enum.count(queries, &(&1.source == "channel_configs")) == 1

    assert Enum.count(
             queries,
             &(&1.source == "messages" and String.starts_with?(&1.query, "INSERT"))
           ) == 1

    assert {:ok, ^captured} = Conversations.capture_canonical_message(facts, attrs, source)
    assert Repo.aggregate(TranscriptMessage, :count) == 5

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts,
               %{attrs | content: "conflicting"},
               source
             )
  end

  property "recipient order and duplicates do not change canonical identity or positions" do
    config = config()
    sender = person("Sender")
    recipients = Enum.map(1..3, &person("Recipient #{&1}")) |> Enum.map(& &1.id)

    {:ok, facts} =
      Facts.new(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: "room-1",
        kind: :replicated,
        actor_person_id: sender.id,
        recipient_person_ids: recipients
      })

    attrs = %{role: "external", content: "invariant", external_message_id: "ordered-fan-out"}
    source = source(config, %{source_scope: "mailbox"})
    assert {:ok, original} = Conversations.capture_canonical_message(facts, attrs, source)

    check all(extra <- list_of(member_of(recipients), max_length: 6), max_runs: 10) do
      reordered = %{facts | recipient_person_ids: extra ++ Enum.reverse(recipients)}
      assert {:ok, ^original} = Conversations.capture_canonical_message(reordered, attrs, source)
      assert Repo.aggregate(TranscriptMessage, :count) == 4
      assert Repo.all(from t in Transcript, select: t.next_position) == [1, 1, 1, 1]
    end
  end

  test "replays reuse a canonical message and position; attaching it to another transcript advances there" do
    config = config()
    room = transcript(config, "room-1")

    thread =
      transcript(config, "room-1:thread-1", %{parent_id: room.id, external_thread_id: "thread-1"})

    assert {:ok, first} = append(room, config, "p-1")
    assert {:ok, replay} = append(room, config, "p-1")
    assert first == replay
    assert first.position == 1

    assert {:ok, second} = append(room, config, "p-2")
    assert second.position == 2
    assert second.message_id != first.message_id

    assert {:ok, in_thread} = append(thread, config, "p-1")
    assert in_thread.message_id == first.message_id
    assert in_thread.position == 1
    assert Repo.get!(Transcript, room.id).next_position == 2
    assert Repo.get!(Transcript, thread.id).next_position == 1

    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 3
  end

  test "a conflicting replay, connector mismatch or fabricated permission coordinate never writes" do
    config = config()
    room = transcript(config, "room-1")
    assert {:ok, original} = append(room, config, "p-1")

    assert {:error, :source_conflict} =
             append(room, config, "p-1", %{content: "different content"})

    assert {:error, :source_scope_mismatch} =
             append(room, config, "p-2", %{}, %{channel_config_id: config.id + 1})

    assert {:error, :source_scope_mismatch} =
             append(room, config, "p-2", %{}, %{provider: "slack"})

    assert {:error, :source_scope_mismatch} =
             append(room, config, "p-2", %{}, %{source_scope: 42})

    Repo.update_all(
      from(t in Transcript, where: t.id == ^room.id),
      set: [permission_resource_id: "forged-resource"]
    )

    assert {:error, :source_scope_mismatch} = append(room, config, "p-2")

    assert Repo.get!(Transcript, room.id).next_position == 1
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.get!(Message, original.message_id).content == "message p-1"
  end

  test "the source scope prevents accidental deduplication across mailboxes" do
    config = config()
    room = transcript(config, "room-1")

    assert {:ok, first} =
             append(room, config, "same-external-id", %{}, %{source_scope: "inbox-a"})

    assert {:ok, second} =
             append(room, config, "same-external-id", %{}, %{source_scope: "inbox-b"})

    assert first.message_id != second.message_id
    assert second.position == first.position + 1
  end

  test "two connectors of one provider never share a canonical source identity" do
    first_config = config()
    second_config = config()
    first_room = transcript(first_config, "room-1")
    second_room = transcript(second_config, "room-1")

    assert {:ok, first} = append(first_room, first_config, "same-post-id")
    assert {:ok, second} = append(second_room, second_config, "same-post-id")
    assert first.message_id != second.message_id
  end

  test "an attachment-only provider message replays without duplication" do
    config = config()
    room = transcript(config, "room-1")
    payload = %{content: nil, attachments: [%{"id" => "picture-1"}]}

    assert {:ok, first} = append(room, config, "photo", payload)
    assert {:ok, same} = append(room, config, "photo", payload)
    assert first == same
    assert Repo.get!(Message, first.message_id).content == ""
  end

  test "messages without a guaranteed external ID are not deduplicated by guessed text" do
    config = config()
    room = transcript(config, "room-1")

    assert {:ok, first} = append(room, config, "ignored", %{external_message_id: nil})
    assert {:ok, second} = append(room, config, "ignored", %{external_message_id: nil})
    assert first.message_id != second.message_id
    assert second.position == first.position + 1
  end

  test "a newly attached old message receives a new transcript position" do
    config = config()
    room = transcript(config, "room-1")
    thread = transcript(config, "room-1:thread-1", %{parent_id: room.id})

    assert {:ok, old} = append(room, config, "old")
    assert {:ok, first_thread} = append(thread, config, "new")
    assert {:ok, attached_late} = append(thread, config, "old")

    assert old.message_id == attached_late.message_id
    assert attached_late.position == first_thread.position + 1
  end

  test "overlapping appends commit unique, contiguous transcript positions" do
    config = config()
    room = transcript(config, "room-1")

    positions =
      1..8
      |> Task.async_stream(fn number -> append(room, config, "concurrent-#{number}") end,
        max_concurrency: 4,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, %{position: position}}} -> position end)

    assert Enum.sort(positions) == Enum.to_list(1..8)
    assert Repo.get!(Transcript, room.id).next_position == 8
  end

  test "reads honor standard grants and never expose private execution fields" do
    config = config()
    room = transcript(config, "room-1")
    authorized = person("Allowed")
    excluded = person("Excluded")
    resource = ChannelHistoryResource.for("mattermost", config.id, "room-1")
    assert {:ok, reply} = append(room, config, "p-1")

    assert {:error, :unauthorized} = Conversations.list_canonical_messages(nil, room.id)
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(excluded, room.id)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(%{excluded | id: 999_999_999}, room.id)

    assert {:ok, public_grant} = Permissions.grant_public(resource)
    assert {:ok, [_]} = Conversations.list_canonical_messages(excluded, room.id)
    assert :ok = Permissions.revoke(resource, public_grant)
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(excluded, room.id)

    assert {:ok, _} =
             Permissions.grant(resource, %{person_id: authorized.id, access_rights: ["read"]})

    Repo.update_all(
      from(m in Message, where: m.id == ^reply.message_id),
      set: [metadata: %{"secret" => "api-key"}, trace: [%{"private" => "tool-result"}]]
    )

    assert {:ok, [item]} = Conversations.list_canonical_messages(authorized, room.id)
    assert item.message_id == reply.message_id
    assert item.position == 1
    assert item.content == "message p-1"
    assert item.attachments == [%{"id" => "a-1"}]
    assert Repo.get!(Message, reply.message_id).attachments == [%{"id" => "a-1"}]
    refute Map.has_key?(item, :metadata)
    refute Map.has_key?(item, :trace)
    refute Map.has_key?(item, :ratings)
    refute Map.has_key?(item, :conversation_id)

    assert {:ok, []} =
             Conversations.list_canonical_messages(authorized, room.id, after_position: 1)

    assert {:error, :not_found} =
             Conversations.list_canonical_messages(authorized, reply.message_id)

    assert {:error, :not_found} =
             Conversations.rate_message_by_id(reply.message_id, %{
               person_id: excluded.id,
               rating: 5
             })

    assert {:error, :invalid_cursor} =
             Conversations.list_canonical_messages(authorized, room.id, after_position: -1)

    assert {:error, :invalid_cursor} =
             Conversations.list_canonical_messages(authorized, room.id, limit: 1_000)

    assert {:ok, _} = append(room, config, "p-2")

    assert {:ok, [first]} =
             Conversations.list_canonical_messages(authorized, room.id, up_to_position: 1)

    assert first.position == 1

    assert {:ok, [second]} =
             Conversations.list_canonical_messages(authorized, room.id, after_position: 1)

    assert second.position == 2
  end

  test "the read projection never carries nested or raw attachment data" do
    config = config()
    room = transcript(config, "room-1")
    reader = person("Allowed")
    resource = ChannelHistoryResource.for("mattermost", config.id, "room-1")

    assert {:ok, _} =
             Permissions.grant(resource, %{person_id: reader.id, access_rights: ["read"]})

    assert {:ok, _} =
             append(room, config, "p-1", %{
               attachments: [
                 %{
                   "id" => %{"secret" => "nested bytes"},
                   "name" => "photo.png",
                   "content" => "raw bytes"
                 }
               ]
             })

    assert {:ok, [item]} = Conversations.list_canonical_messages(reader, room.id)
    assert item.attachments == [%{"name" => "photo.png"}]
  end

  test "Direct access follows participant grants and revocation, not a single owner" do
    config = config()
    room = transcript(config, "direct:room-1", %{strategy: "direct"})
    alice = person("Alice")
    bob = person("Bob")
    resource = ChannelHistoryResource.for("mattermost", config.id, "room-1")
    assert {:ok, _} = append(room, config, "p-1")

    assert {:ok, alice_grant} =
             Permissions.grant(resource, %{person_id: alice.id, access_rights: ["read"]})

    assert {:ok, _} = Permissions.grant(resource, %{person_id: bob.id, access_rights: ["read"]})
    assert {:ok, [_]} = Conversations.list_canonical_messages(alice, room.id)
    assert {:ok, [_]} = Conversations.list_canonical_messages(bob, room.id)
    assert :ok = Permissions.revoke(resource, alice_grant)
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(alice, room.id)
    assert {:ok, [_]} = Conversations.list_canonical_messages(bob, room.id)
  end

  test "archived connector keeps authorized history but cannot receive a new message" do
    config = config()
    room = transcript(config, "room-1")
    reader = person("Historical Reader")
    resource = ChannelHistoryResource.for("mattermost", config.id, "room-1")

    assert {:ok, _} =
             Permissions.grant(resource, %{person_id: reader.id, access_rights: ["read"]})

    assert {:ok, _} = append(room, config, "old")
    assert {:ok, _} = ChannelConfig.archive(config)

    assert {:ok, [_]} = Conversations.list_canonical_messages(reader, room.id)
    assert {:error, :source_scope_mismatch} = append(room, config, "new")
  end

  test "Replicated owner sees only recipient-specific associations" do
    config = config()
    recipient = person("Recipient")
    other = person("Other")

    room =
      transcript(config, "recipient:#{recipient.id}", %{
        strategy: "replicated",
        owner_person_id: recipient.id,
        permission_resource_type: "person_history",
        permission_resource_id: "recipient:#{recipient.id}"
      })

    assert {:error, :source_scope_mismatch} =
             append(room, config, "p-1", %{}, %{recipient_person_id: other.id})

    assert {:ok, _} = append(room, config, "p-1", %{}, %{recipient_person_id: recipient.id})
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(recipient, room.id)

    assert {:ok, _} =
             Permissions.grant({room.permission_resource_type, room.permission_resource_id}, %{
               person_id: recipient.id,
               access_rights: ["read"]
             })

    assert {:ok, [_]} = Conversations.list_canonical_messages(recipient, room.id)
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(other, room.id)
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(nil, room.id)
  end

  property "replaying a provider ID never consumes a second position" do
    config = config()
    room = transcript(config, "room-1")

    check all(
            external_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
            max_runs: 14
          ) do
      scoped_id = "#{System.unique_integer([:positive])}:#{external_id}"
      assert {:ok, first} = append(room, config, scoped_id)
      assert {:ok, second} = append(room, config, scoped_id)
      assert first == second
    end

    assert Repo.get!(Transcript, room.id).next_position == 14
  end

  test "append accepts the complete opaque source-scope boundary" do
    config = config()
    room = transcript(config, "room-long-scope")
    scope = String.duplicate("é", 127) <> "a"

    assert byte_size(scope) == 255
    assert {:ok, first} = append(room, config, "long-scope", %{}, %{source_scope: scope})
    assert {:ok, replay} = append(room, config, "long-scope", %{}, %{source_scope: scope})
    assert first == replay
  end

  test "capture and append reject invalid request shapes without writes" do
    config = config()
    room = transcript(config, "room-1")
    actor = person("Invalid request actor")

    {:ok, facts} =
      Facts.new(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: "room-1",
        kind: :channel,
        actor_person_id: actor.id
      })

    assert {:error, :invalid_request} =
             Conversations.capture_canonical_message(:not_facts, %{}, %{})

    assert {:error, :invalid_request} = Conversations.capture_canonical_message(facts, [], %{})
    assert {:error, :invalid_request} = Conversations.capture_canonical_message(facts, %{}, [])
    assert {:error, :invalid_request} = Conversations.append_canonical_message(room.id, [], %{})
    assert {:error, :invalid_request} = Conversations.append_canonical_message(room.id, %{}, [])
    assert {:error, :not_found} = Conversations.append_canonical_message("not-a-uuid", %{}, %{})

    missing_id = "00000000-0000-4000-8000-000000000000"
    assert {:error, :not_found} = Conversations.append_canonical_message(missing_id, %{}, %{})
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(TranscriptMessage, :count) == 0
    assert Repo.get!(Transcript, room.id).next_position == 0
  end

  test "legacy source lookup rejects ambiguous user messages in the same connector scope" do
    config = config()
    first = legacy_conversation(config)
    second = legacy_conversation(config)
    legacy_user_message(first, "duplicate-provider-id")
    legacy_user_message(second, "duplicate-provider-id")

    {:ok, facts} =
      Facts.new(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: "room-1",
        kind: :channel,
        actor_person_id: person("Ambiguous legacy actor").id
      })

    attrs = %{
      role: "external",
      content: "legacy content",
      external_message_id: "duplicate-provider-id",
      author_id: "legacy-author"
    }

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(facts, attrs, source(config, %{}))

    assert Repo.aggregate(Transcript, :count) == 0
    assert Repo.aggregate(TranscriptMessage, :count) == 0
  end

  test "internal admin listing is bounded and validates legacy resource coordinates" do
    first = legacy_conversation(nil)
    first_message = legacy_user_message(first, "legacy-1", "first")
    second_message = legacy_user_message(first, "legacy-2", "second")

    transcript =
      %Transcript{}
      |> Transcript.changeset(%{
        strategy: "legacy",
        provider: "legacy",
        scope_key: "legacy:#{first.id}",
        conversation_id: first.id,
        permission_resource_type: "legacy_conversation",
        permission_resource_id: first.id
      })
      |> Repo.insert!()

    for {message, position} <- [{first_message, 1}, {second_message, 2}] do
      %TranscriptMessage{}
      |> TranscriptMessage.changeset(%{
        transcript_id: transcript.id,
        message_id: message.id,
        position: position,
        provenance: "legacy_import"
      })
      |> Repo.insert!()
    end

    reader = person("Legacy reader")
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(reader, transcript.id)
    assert {:error, :not_found} = TranscriptHistory.list_admin(transcript.id, :invalid_opts)
    assert {:ok, [item]} = TranscriptHistory.list_admin(transcript.id, limit: 1)
    assert item.message_id == first_message.id
    assert item.position == 1

    Repo.update_all(
      from(t in Transcript, where: t.id == ^transcript.id),
      set: [permission_resource_id: "forged"]
    )

    assert {:error, :not_found} = TranscriptHistory.list_admin(transcript.id)

    assert {:error, :not_found} =
             TranscriptHistory.list_admin("00000000-0000-4000-8000-000000000000")
  end

  test "prepared association checks its durable confirmation receipt before placement" do
    config = config()
    room = transcript(config, "room-1")

    attrs = %{
      role: "external",
      content: "confirmed",
      external_message_id: "confirmed-1",
      source_provider: "mattermost",
      source_account_key: "mattermost:#{config.id}:default"
    }

    valid =
      %Message{}
      |> Message.canonical_changeset(attrs)
      |> Ecto.Changeset.put_change(:metadata, %{
        "delivery_confirmation" => %{
          "provider" => "mattermost",
          "channel_config_id" => config.id,
          "channel_id" => "room-1"
        }
      })
      |> Repo.insert!()

    assert {:ok, :ok} = TranscriptHistory.associate_prepared(valid, [room.id])
    assert Repo.get!(Transcript, room.id).next_position == 1

    invalid =
      %Message{}
      |> Message.canonical_changeset(%{attrs | external_message_id: "confirmed-2"})
      |> Ecto.Changeset.put_change(:metadata, %{
        "delivery_confirmation" => %{
          "provider" => "slack",
          "channel_config_id" => config.id,
          "channel_id" => "room-1"
        }
      })
      |> Repo.insert!()

    assert {:error, :source_scope_mismatch} =
             TranscriptHistory.associate_prepared(invalid, [room.id])

    assert Repo.get!(Transcript, room.id).next_position == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 1
  end

  test "valid connector with mismatched parent scope fails closed before appending" do
    parent_config = config()
    child_config = config()
    parent = transcript(parent_config, "parent")

    child =
      transcript(child_config, "child", %{
        parent_id: parent.id,
        external_thread_id: "thread-1"
      })

    assert {:error, :source_scope_mismatch} = append(child, child_config, "invalid-parent")
    assert Repo.get!(Transcript, child.id).next_position == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "confirmed legacy conversation history must match the transcript connector" do
    config = config()
    other_config = config()
    conversation = legacy_conversation(other_config)
    input = legacy_user_message(conversation, "execution-input", "question")

    Repo.update_all(from(m in Message, where: m.id == ^input.id),
      set: [author_id: "room-1"]
    )

    response =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "assistant",
        content: "answer",
        metadata: %{"in_reply_to_message_id" => input.id}
      })
      |> Repo.insert!()

    owner = person("Confirmed history owner")

    transcript =
      %Transcript{}
      |> Transcript.changeset(%{
        strategy: "replicated",
        provider: "mattermost",
        channel_config_id: config.id,
        external_channel_id: "room-1",
        scope_key: "confirmed:#{owner.id}",
        owner_person_id: owner.id,
        permission_resource_type: "person_history",
        permission_resource_id: "recipient:#{owner.id}"
      })
      |> Repo.insert!()

    response_attrs = %{
      role: "assistant",
      content: "answer",
      external_message_id: "confirmed-response"
    }

    context = %{
      provider: "mattermost",
      channel_config_id: config.id,
      provenance: "provider_confirmed",
      source_scope: "default",
      recipient_person_id: owner.id,
      existing_message_id: response.id
    }

    assert {:error, :source_conflict} =
             Conversations.append_canonical_message(transcript.id, response_attrs, context)

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id),
      set: [channel_config_id: config.id]
    )

    assert {:ok, placement} =
             Conversations.append_canonical_message(transcript.id, response_attrs, context)

    assert placement.message_id == response.id
    assert placement.position == 1
  end

  test "a transcript whose connector no longer matches its provider refuses writes" do
    config = config()
    room = transcript(config, "room-1")
    Repo.update_all(from(c in ChannelConfig, where: c.id == ^config.id), set: [provider: "slack"])

    assert {:error, :source_scope_mismatch} = append(room, config, "wrong-connector-provider")
    assert Repo.get!(Transcript, room.id).next_position == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "conversation-less canonical user messages cannot be reused as execution messages" do
    canonical =
      %Message{}
      |> Message.canonical_changeset(%{role: "user", content: "canonical input"})
      |> Repo.insert!()

    config = config()
    room = transcript(config, "room-1")

    assert {:error, :source_conflict} =
             append(
               room,
               config,
               "new-provider-id",
               %{role: "user", content: "canonical input"},
               %{
                 existing_message_id: canonical.id
               }
             )

    assert Repo.get!(Message, canonical.id) == canonical
    assert Repo.get!(Transcript, room.id).next_position == 0
    assert Repo.aggregate(TranscriptMessage, :count) == 0
    assert Repo.aggregate(Message, :count) == 1
  end

  test "conversation-less canonical assistants cannot be reused as confirmed execution responses" do
    canonical =
      %Message{}
      |> Message.canonical_changeset(%{role: "assistant", content: "canonical answer"})
      |> Repo.insert!()

    config = config()
    owner = person("Confirmed response owner")

    room =
      transcript(config, "replicated:#{owner.id}", %{
        strategy: "replicated",
        owner_person_id: owner.id,
        permission_resource_type: "person_history",
        permission_resource_id: "recipient:#{owner.id}"
      })

    assert {:error, :source_conflict} =
             append(
               room,
               config,
               "confirmed-canonical-response",
               %{role: "assistant", content: "canonical answer"},
               %{
                 existing_message_id: canonical.id,
                 provenance: "provider_confirmed",
                 recipient_person_id: owner.id
               }
             )

    assert Repo.get!(Message, canonical.id) == canonical
    assert Repo.get!(Transcript, room.id).next_position == 0
    assert Repo.aggregate(TranscriptMessage, :count) == 0
    assert Repo.aggregate(Message, :count) == 1
  end

  test "attachment sanitization drops non-lists and preserves only safe descriptor fields" do
    config = config()
    room = transcript(config, "room-1")

    for {suffix, attachments} <- [
          {"nil", nil},
          {"map", %{"id" => "ignored"}},
          {"scalar", "ignored"}
        ] do
      assert {:ok, placement} =
               append(room, config, "attachments-#{suffix}", %{attachments: attachments})

      assert Repo.get!(Message, placement.message_id).attachments == []

      assert {:ok, [item]} =
               Conversations.list_canonical_messages(
                 person_for(config),
                 room.id,
                 after_position: placement.position - 1,
                 limit: 1
               )

      assert item.attachments == []
    end

    assert {:ok, placement} =
             append(room, config, "attachments-safe", %{
               attachments: [
                 nil,
                 %{},
                 %{
                   "id" => %{"secret" => "nested"},
                   "name" => "photo.png",
                   "size" => -1,
                   "content" => "raw bytes"
                 },
                 %{
                   "id" => "file-1",
                   "mime_type" => "image/png",
                   "size" => 0,
                   "path" => "/private/path",
                   "nested" => %{"secret" => true}
                 }
               ]
             })

    expected = [
      %{"name" => "photo.png"},
      %{"id" => "file-1", "mime_type" => "image/png", "size" => 0}
    ]

    assert Repo.get!(Message, placement.message_id).attachments == expected

    assert {:ok, [item]} =
             Conversations.list_canonical_messages(
               person_for(config),
               room.id,
               after_position: placement.position - 1,
               limit: 1
             )

    assert item.attachments == expected
  end

  defp person_for(config) do
    reader = person("Attachment reader")
    resource = ChannelHistoryResource.for("mattermost", config.id, "room-1")
    {:ok, _} = Permissions.grant(resource, %{person_id: reader.id, access_rights: ["read"]})
    reader
  end
end
