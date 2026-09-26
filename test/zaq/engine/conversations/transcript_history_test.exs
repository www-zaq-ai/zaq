defmodule Zaq.Engine.Conversations.TranscriptHistoryTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, Transcript, TranscriptMessage}
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

  test "reads require a direct Person grant and never expose private execution fields" do
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

    assert {:ok, _} = Permissions.grant_public(resource)
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
end
