defmodule Zaq.Engine.Conversations.CanonicalHistoryCaptureTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.ChannelHistoryAdmin
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, MessageRating, Transcript, TranscriptMessage}
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.HistoryDeliveryWorker
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.Permissions.ResourcePermission

  defp person(name) do
    {:ok, person} = People.create_person(%{"full_name" => name})
    person
  end

  defp connector(provider) do
    if provider == "email:imap" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "SMTP for history capture",
        provider: "email:smtp",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "fixture-token"
      })
      |> Repo.insert!()
    end

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "History capture #{System.unique_integer([:positive])}",
      provider: provider,
      kind: "retrieval",
      url: "https://example.invalid",
      token: "fixture-token",
      settings:
        if(provider == "email:imap",
          do: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}},
          else: %{}
        )
    })
    |> Repo.insert!()
  end

  defp facts(config, actor, kind, overrides \\ %{}) do
    struct!(
      Facts,
      Map.merge(
        %{
          provider: config.provider,
          channel_config_id: config.id,
          channel_id: "room-1",
          kind: kind,
          actor_person_id: actor.id
        },
        overrides
      )
    )
  end

  defp source(config, overrides \\ %{}) do
    Map.merge(
      %{
        provider: config.provider,
        channel_config_id: config.id,
        provenance: "provider_event"
      },
      overrides
    )
  end

  defp message(id, content \\ "hello") do
    %{
      role: "external",
      content: content,
      author_id: "sender@example.com",
      external_message_id: id
    }
  end

  defp admitted_incoming(config) do
    %{
      content: "hello",
      channel_id: "room-1",
      author_id: "sender@example.com",
      message_id: "legacy-1",
      provider: :mattermost,
      routing_context: %{channel_config_id: config.id, history_kind: :channel}
    }
    |> Incoming.new()
    |> CommunicationBridge.put_conversation_identity()
  end

  test "a shared channel stores the root and thread separately and replays at one position" do
    owner = person("Owner")
    stranger = person("Stranger")
    config = connector("mattermost")
    shared = facts(config, owner, :channel)

    assert {:ok, root} =
             Conversations.capture_canonical_message(shared, message("root-1"), source(config))

    assert root.position == 1

    assert {:ok, ^root} =
             Conversations.capture_canonical_message(shared, message("root-1"), source(config))

    assert {:ok, thread} =
             Conversations.capture_canonical_message(
               %{shared | thread_id: "thread-1"},
               message("reply-1"),
               source(config)
             )

    assert thread.transcript_id != root.transcript_id
    assert Repo.get!(Transcript, thread.transcript_id).parent_id == root.transcript_id
    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 2

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(stranger, root.transcript_id)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(owner, thread.transcript_id)

    resource = ChannelHistoryResource.for(config.provider, config.id, "room-1")
    assert {:ok, _} = Permissions.grant(resource, %{person_id: owner.id, access_rights: ["read"]})

    assert {:ok, [%{content: "hello"}]} =
             Conversations.list_canonical_messages(owner, root.transcript_id)

    assert {:ok, [%{content: "hello"}]} =
             Conversations.list_canonical_messages(owner, thread.transcript_id)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(stranger, thread.transcript_id)
  end

  test "a thread arriving before its root creates an empty parent without exposing siblings" do
    reader = person("Reader")
    config = connector("mattermost")
    shared = facts(config, reader, :channel)

    assert {:ok, first} =
             Conversations.capture_canonical_message(
               %{shared | thread_id: "thread-1"},
               message("first-reply"),
               source(config)
             )

    assert {:ok, sibling} =
             Conversations.capture_canonical_message(
               %{shared | thread_id: "thread-2"},
               message("other-reply"),
               source(config)
             )

    first_parent = Repo.get!(Transcript, first.transcript_id).parent_id
    assert Repo.get!(Transcript, sibling.transcript_id).parent_id == first_parent
    assert Repo.get!(Transcript, first_parent).next_position == 0
    assert Repo.aggregate(Transcript, :count) == 3

    resource = ChannelHistoryResource.for(config.provider, config.id, "room-1")

    assert {:ok, _} =
             Permissions.grant(resource, %{person_id: reader.id, access_rights: ["read"]})

    assert {:ok, []} = Conversations.list_canonical_messages(reader, first_parent)

    assert {:ok, [%{message_id: first_id}]} =
             Conversations.list_canonical_messages(reader, first.transcript_id)

    assert first_id == first.message_id

    assert {:ok, [%{message_id: sibling_id}]} =
             Conversations.list_canonical_messages(reader, sibling.transcript_id)

    assert sibling_id == sibling.message_id
  end

  test "replicated messages have only this message's recipients and never backfill earlier audience" do
    sender = person("Sender")
    first = person("First")
    later = person("Later")
    config = connector("email:imap")

    assert {:ok, first_delivery} =
             Conversations.capture_canonical_message(
               facts(config, sender, :replicated, %{recipient_person_ids: [first.id]}),
               message("email-1", "old content"),
               source(config, %{source_scope: "INBOX"})
             )

    assert {:ok, second_delivery} =
             Conversations.capture_canonical_message(
               facts(config, sender, :replicated, %{recipient_person_ids: [later.id]}),
               message("email-2", "new content"),
               source(config, %{source_scope: "INBOX"})
             )

    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 4

    assert {:ok, [%{content: "old content"}]} =
             Conversations.list_canonical_messages(first, first_delivery.transcript_ids[first.id])

    assert {:ok, [%{content: "new content"}]} =
             Conversations.list_canonical_messages(
               later,
               second_delivery.transcript_ids[later.id]
             )

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(later, first_delivery.transcript_ids[first.id])

    assert {:ok, [%{content: "old content"}, %{content: "new content"}]} =
             Conversations.list_canonical_messages(
               sender,
               first_delivery.transcript_ids[sender.id]
             )
  end

  test "replica grants are revocable and replay or another conversation cannot restore access" do
    owner = person("Owner")
    config = connector("email:imap")
    input = facts(config, owner, :replicated)
    origin = source(config, %{source_scope: "INBOX"})

    assert {:ok, captured} =
             Conversations.capture_canonical_message(input, message("revocable"), origin)

    transcript = Repo.get!(Transcript, captured.transcript_ids[owner.id])
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}
    assert [grant] = Permissions.list_direct(resource)
    assert grant.person_id == owner.id
    assert Permissions.can?(owner, :read, resource)

    assert {:ok, %{grants: [%{person_id: owner_id, source: "channel_history:recipient"}]}} =
             ChannelHistoryAdmin.dispatch(%{op: :detail, id: transcript.id})

    assert owner_id == owner.id
    assert :ok = Permissions.revoke(resource, grant)
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(owner, transcript.id)
    assert {:ok, _} = Conversations.capture_canonical_message(input, message("revocable"), origin)

    assert {:ok, _} =
             Conversations.capture_canonical_message(
               %{input | channel_id: "other-conversation"},
               message("other"),
               origin
             )

    assert Permissions.list_direct(resource) == []
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(owner, transcript.id)
  end

  test "shared parent and thread reads honor ordinary team grants and revocation" do
    reader = person("Team reader")
    config = connector("mattermost")
    {:ok, team} = People.create_team(%{name: "History readers"})
    {:ok, reader} = People.assign_team(reader, team.id)
    input = facts(config, reader, :channel)

    assert {:ok, root} =
             Conversations.capture_canonical_message(input, message("team-root"), source(config))

    assert {:ok, thread} =
             Conversations.capture_canonical_message(
               %{input | thread_id: "team-root"},
               message("team-reply"),
               source(config)
             )

    resource = ChannelHistoryResource.for(config.provider, config.id, "room-1")

    assert {:ok, grant} =
             Permissions.grant(resource, %{team_id: team.id, access_rights: ["read"]})

    for id <- [root.transcript_id, thread.transcript_id] do
      assert {:ok, %{grants: [%{person_id: nil, team_id: team_id, access_rights: ["read"]}]}} =
               ChannelHistoryAdmin.dispatch(%{op: :detail, id: id})

      assert team_id == team.id
    end

    for id <- [root.transcript_id, thread.transcript_id],
        do: assert({:ok, [_]} = Conversations.list_canonical_messages(reader, id))

    assert :ok = Permissions.revoke(resource, grant)

    for id <- [root.transcript_id, thread.transcript_id],
        do: assert({:error, :unauthorized} = Conversations.list_canonical_messages(reader, id))
  end

  test "a conflicting replay cannot extend a replicated message's audience" do
    sender = person("Sender")
    first = person("First")
    hidden = person("Hidden")
    config = connector("email:imap")
    initial = facts(config, sender, :replicated, %{recipient_person_ids: [first.id]})
    source = source(config, %{source_scope: "INBOX"})

    assert {:ok, capture} =
             Conversations.capture_canonical_message(initial, message("email-1"), source)

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               %{initial | recipient_person_ids: [first.id, hidden.id]},
               message("email-1"),
               source
             )

    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 2

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(hidden, capture.transcript_id)
  end

  test "concurrent recipient replays commit only one audience" do
    sender = person("Sender")
    first = person("First")
    second = person("Second")
    config = connector("email:imap")
    context = source(config, %{source_scope: "INBOX"})

    results =
      [first.id, second.id]
      |> Task.async_stream(
        fn id ->
          Conversations.capture_canonical_message(
            facts(config, sender, :replicated, %{recipient_person_ids: [id]}),
            message("concurrent-email"),
            context
          )
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :source_conflict})) == 1
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 2
  end

  test "invalid source or actor never creates a transcript or message" do
    owner = person("Owner")
    config = connector("mattermost")
    facts = facts(config, owner, :channel)

    assert {:error, _} =
             Conversations.capture_canonical_message(
               facts,
               message("a"),
               source(config, %{channel_config_id: config.id + 1})
             )

    assert {:error, _} =
             Conversations.capture_canonical_message(
               %{facts | actor_person_id: nil},
               message("b"),
               source(config)
             )

    assert Repo.aggregate(Transcript, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "a missing Person cannot become a recipient or actor" do
    sender = person("Sender")
    config = connector("email:imap")
    missing_id = sender.id + 1_000_000
    context = source(config, %{source_scope: "INBOX"})

    assert {:error, :invalid_history_person} =
             Conversations.capture_canonical_message(
               facts(config, sender, :replicated, %{recipient_person_ids: [missing_id]}),
               message("email-1"),
               context
             )

    assert {:error, :invalid_history_person} =
             Conversations.capture_canonical_message(
               facts(config, sender, :replicated, %{actor_person_id: missing_id}),
               message("email-2"),
               context
             )

    assert Repo.aggregate(Transcript, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "email IDs require a scoped receiving account or mailbox" do
    sender = person("Sender")
    config = connector("email:imap")

    assert {:error, :invalid_history_source} =
             Conversations.capture_canonical_message(
               facts(config, sender, :replicated),
               message("uid-1"),
               source(config)
             )

    assert Repo.aggregate(Transcript, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "a failed multi-recipient append rolls back every transcript and grant" do
    sender = person("Sender")
    recipient = person("Recipient")
    config = connector("email:imap")

    assert {:error, %Ecto.Changeset{}} =
             Conversations.capture_canonical_message(
               facts(config, sender, :replicated, %{recipient_person_ids: [recipient.id]}),
               %{role: "external", external_message_id: "empty-body"},
               source(config, %{source_scope: "INBOX"})
             )

    assert Repo.aggregate(Transcript, :count) == 0
    assert Repo.aggregate(TranscriptMessage, :count) == 0
    assert Repo.aggregate(Message, :count) == 0
  end

  test "an admitted incoming message keeps its UUID, rating, and private metadata in canonical history" do
    reader = person("Reader")
    config = connector("mattermost")

    assert {:ok, binding} = Conversations.admit_incoming(admitted_incoming(config))
    existing_id = binding.user_message_id

    legacy =
      existing_id
      |> then(&Repo.get!(Message, &1))
      |> Ecto.Changeset.change(trace: [%{"private" => "not in history"}])
      |> Repo.update!()

    %MessageRating{}
    |> MessageRating.changeset(%{message_id: existing_id, person_id: reader.id, rating: 5})
    |> Repo.insert!()

    assert {:ok, capture} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               %{message("legacy-1") | role: "user"},
               source(config, %{existing_message_id: existing_id})
             )

    assert capture.message_id == existing_id
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.get!(Message, existing_id).conversation_id == binding.conversation_id
    assert Repo.get!(Message, existing_id).metadata == legacy.metadata
    assert Repo.get!(Message, existing_id).trace == legacy.trace
    assert Repo.get_by!(MessageRating, person_id: reader.id).message_id == existing_id

    assert {:ok, ^capture} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               %{message("legacy-1") | role: "user"},
               source(config, %{existing_message_id: existing_id})
             )
  end

  test "a finalized chat answer enters the transcript only after a confirmed delivery" do
    reader = person("Reader")
    config = connector("mattermost")
    incoming = admitted_incoming(config)

    assert {:ok, captured} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("legacy-1"),
               source(config)
             )

    assert {:ok, _} =
             Permissions.grant(
               ChannelHistoryResource.for(config.provider, config.id, "room-1"),
               %{
                 person_id: reader.id,
                 access_rights: ["read"]
               }
             )

    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    assert binding.user_message_id == captured.message_id
    captured_id = captured.message_id

    assert {:ok, %{assistant_message_id: response_id}} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{
                 answer: "Answer from ZAQ",
                 error: false,
                 trace: [%{"secret" => "private execution"}]
               }
             )

    assert {:ok, [%{message_id: ^captured_id}]} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    delivery = %{
      confirmation: :confirmed,
      kind: :channel,
      provider: "mattermost",
      message_id: "confirmed-provider-post",
      channel_config_id: config.id,
      channel_id: "room-1",
      user_message_id: captured_id,
      assistant_message_id: response_id
    }

    assert {:error, :unavailable_history_input} =
             HistoryIngress.capture_confirmed(%{
               delivery
               | channel_id: "other-room"
             })

    assert {:ok, [%{message_id: ^captured_id}]} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    assert {:ok, ^response_id} =
             HistoryIngress.record_confirmation(Map.put(delivery, :confirmation, :confirmed))

    assert {:ok, [%{message_id: ^captured_id}]} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    config |> ChannelConfig.changeset(%{enabled: false}) |> Repo.update!()
    assert {:error, :invalid_delivery_scope} = HistoryIngress.associate_confirmation(response_id)

    assert [%Oban.Job{args: args}] = all_enqueued(worker: HistoryDeliveryWorker)
    assert args == %{"message_id" => response_id}
    assert {:error, :history_association_unavailable} = perform_job(HistoryDeliveryWorker, args)
    Repo.reload!(config) |> ChannelConfig.changeset(%{enabled: true}) |> Repo.update!()
    assert :ok = perform_job(HistoryDeliveryWorker, args)
    assert :ok = perform_job(HistoryDeliveryWorker, args)

    assert {:error, :conflicting_delivery_confirmation} =
             HistoryIngress.capture_confirmed(%{delivery | message_id: "other-provider-post"})

    assert Repo.get!(Message, response_id).metadata["delivery_confirmation"] == %{
             "provider" => "mattermost",
             "channel_config_id" => config.id,
             "channel_id" => "room-1",
             "message_id" => "confirmed-provider-post",
             "conversation_id" => nil
           }

    assert {:ok,
            [%{message_id: ^captured_id}, %{message_id: ^response_id, content: "Answer from ZAQ"}]} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    assert Repo.get!(Message, response_id).conversation_id == binding.conversation_id
    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 2
  end

  test "a passive replay after admission attaches the existing legacy UUID without an explicit binding" do
    reader = person("Reader")
    config = connector("mattermost")
    assert {:ok, admitted} = Conversations.admit_incoming(admitted_incoming(config))

    assert {:ok, capture} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("legacy-1"),
               source(config)
             )

    assert capture.message_id == admitted.user_message_id
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.get!(Message, admitted.user_message_id).role == "user"
    assert Repo.aggregate(TranscriptMessage, :count) == 1

    assert {:ok, ^capture} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("legacy-1"),
               source(config)
             )
  end

  test "simultaneous admission and capture share one UUID regardless of order" do
    reader = person("Reader")
    config = connector("mattermost")

    for index <- 1..4 do
      external_id = "race-#{index}"
      incoming = %{admitted_incoming(config) | message_id: external_id}

      results =
        [
          fn -> Conversations.admit_incoming(incoming) end,
          fn ->
            Conversations.capture_canonical_message(
              facts(config, reader, :channel),
              message(external_id),
              source(config)
            )
          end
        ]
        |> Task.async_stream(fn operation -> operation.() end,
          max_concurrency: 2,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [{:ok, admitted}, {:ok, captured}] = results
      assert admitted.user_message_id == captured.message_id
      assert admitted.admitted?
      assert is_binary(admitted.finalization_token)
      assert Repo.get!(Message, captured.message_id).conversation_id == admitted.conversation_id
    end

    assert Repo.aggregate(Message, :count) == 4
    assert Repo.aggregate(TranscriptMessage, :count) == 4
  end

  test "an addressed replay adopts an earlier passive canonical message without duplicating it" do
    reader = person("Reader")
    config = connector("mattermost")

    assert {:ok, passive} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("legacy-1"),
               source(config)
             )

    assert {:ok, first} = Conversations.admit_incoming(admitted_incoming(config))
    assert first.user_message_id == passive.message_id
    assert first.admitted?
    assert is_binary(first.finalization_token)

    assert {:ok, ^passive} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("legacy-1"),
               source(config)
             )

    assert {:ok, second} = Conversations.admit_incoming(admitted_incoming(config))
    assert second.user_message_id == passive.message_id
    refute second.admitted?
    assert second.finalization_token == nil
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.get!(Message, passive.message_id).role == "user"
  end

  test "a canonical source in another room cannot be adopted as this request" do
    reader = person("Reader")
    config = connector("mattermost")

    assert {:ok, passive} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("legacy-1"),
               source(config)
             )

    other_room =
      admitted_incoming(config)
      |> Map.put(:channel_id, "other-room")
      |> CommunicationBridge.put_conversation_identity()

    assert {:error, :source_conflict} = Conversations.admit_incoming(other_room)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.get!(Message, passive.message_id).conversation_id == nil
  end

  test "an admitted provider replay cannot silently replace author or content" do
    config = connector("mattermost")
    incoming = admitted_incoming(config)
    assert {:ok, admitted} = Conversations.admit_incoming(incoming)

    assert {:error, :source_conflict} =
             Conversations.admit_incoming(%{incoming | author_id: "other@example.com"})

    assert {:error, :source_conflict} =
             Conversations.admit_incoming(%{incoming | content: "changed content"})

    assert Repo.aggregate(Message, :count) == 1
    assert Repo.get!(Message, admitted.user_message_id).author_id == incoming.author_id
  end

  test "a provider ID already captured in another room cannot be placed in a new room" do
    reader = person("Reader")
    config = connector("mattermost")

    assert {:ok, first} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("same-provider-id"),
               source(config)
             )

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               %{facts(config, reader, :channel) | channel_id: "another-room"},
               message("same-provider-id"),
               source(config)
             )

    assert Repo.aggregate(TranscriptMessage, :count) == 1
    assert Repo.get!(Message, first.message_id).conversation_id == nil
  end

  test "a disabled connector cannot capture a new provider message" do
    reader = person("Reader")
    config = connector("mattermost")
    config |> ChannelConfig.changeset(%{enabled: false}) |> Repo.update!()

    assert {:error, :source_scope_mismatch} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("disabled-1"),
               source(config)
             )

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Transcript, :count) == 0
  end

  test "disabling a connector stops writes without erasing already-granted history" do
    reader = person("Reader")
    config = connector("mattermost")

    assert {:ok, captured} =
             Conversations.capture_canonical_message(
               facts(config, reader, :direct),
               message("before-disable"),
               source(config)
             )

    config |> ChannelConfig.changeset(%{enabled: false}) |> Repo.update!()

    assert {:ok, [%{message_id: message_id}]} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    assert message_id == captured.message_id

    assert {:error, :source_scope_mismatch} =
             Conversations.capture_canonical_message(
               facts(config, reader, :direct),
               message("after-disable"),
               source(config)
             )

    assert Repo.aggregate(Message, :count) == 1
  end

  test "an addressed replay cannot adopt a different history strategy or sibling thread" do
    reader = person("Reader")
    config = connector("mattermost")
    shared = facts(config, reader, :channel, %{thread_id: "thread-1"})

    assert {:ok, passive} =
             Conversations.capture_canonical_message(shared, message("legacy-1"), source(config))

    first_thread =
      admitted_incoming(config)
      |> Map.put(:thread_id, "thread-1")
      |> CommunicationBridge.put_conversation_identity()

    other_thread =
      first_thread
      |> Map.put(:thread_id, "thread-2")
      |> CommunicationBridge.put_conversation_identity()

    wrong_strategy = %{
      first_thread
      | routing_context: %{first_thread.routing_context | history_kind: :direct}
    }

    assert {:error, :source_conflict} = Conversations.admit_incoming(other_thread)
    assert {:error, :source_conflict} = Conversations.admit_incoming(wrong_strategy)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.get!(Message, passive.message_id).conversation_id == nil
  end

  test "a mismatched admitted UUID or source does not create a placement" do
    reader = person("Reader")
    config = connector("mattermost")

    assert {:ok, binding} = Conversations.admit_incoming(admitted_incoming(config))
    context = source(config, %{existing_message_id: binding.user_message_id})

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               %{message("different-id") | role: "user"},
               context
             )

    other_config = connector("mattermost")

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts(other_config, reader, :channel),
               %{message("legacy-1") | role: "user"},
               source(other_config, %{existing_message_id: binding.user_message_id})
             )

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               %{facts(config, reader, :channel) | channel_id: "other-room"},
               %{message("legacy-1") | role: "user"},
               context
             )

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               %{message("legacy-1") | role: "user", author_id: "another@example.com"},
               context
             )

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               %{message("legacy-1") | role: "assistant"},
               source(config)
             )

    assert Repo.get!(Message, binding.user_message_id).source_provider == nil
    assert Repo.aggregate(Transcript, :count) == 0
    assert Repo.aggregate(TranscriptMessage, :count) == 0
  end

  test "an older admitted row without author evidence cannot be silently assigned an audience" do
    reader = person("Reader")
    config = connector("mattermost")
    assert {:ok, binding} = Conversations.admit_incoming(admitted_incoming(config))

    binding.user_message_id
    |> then(&Repo.get!(Message, &1))
    |> Ecto.Changeset.change(author_id: nil)
    |> Repo.update!()

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts(config, reader, :channel),
               message("legacy-1"),
               source(config)
             )

    assert Repo.aggregate(TranscriptMessage, :count) == 0
    assert Repo.get!(Message, binding.user_message_id).source_provider == nil
  end

  test "an admitted IMAP message reuses its UUID only in its stamped mailbox and connector" do
    sender = person("Sender")
    config = connector("email:imap")

    incoming =
      %{
        content: "hello",
        channel_id: "sender@example.com",
        author_id: "sender@example.com",
        message_id: "legacy-email-1",
        provider: :"email:imap",
        routing_context: %{
          channel_config_id: config.id,
          history_kind: :replicated,
          source_scope: "INBOX",
          identity_platform: "email",
          audience: %{platform: "email", sender: "sender@example.com", recipients: []}
        },
        metadata: %{"email" => %{"mailbox" => "INBOX"}}
      }
      |> Incoming.new()
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    facts = %{facts(config, sender, :replicated) | channel_id: "sender@example.com"}

    assert {:error, :source_conflict} =
             Conversations.admit_incoming(%{
               incoming
               | routing_context: %{incoming.routing_context | source_scope: "SENT"}
             })

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts,
               %{message("legacy-email-1") | role: "user"},
               source(config, %{
                 source_scope: "SENT",
                 existing_message_id: binding.user_message_id
               })
             )

    assert {:ok, capture} =
             Conversations.capture_canonical_message(
               facts,
               %{message("legacy-email-1") | role: "user"},
               source(config, %{
                 source_scope: "INBOX",
                 existing_message_id: binding.user_message_id
               })
             )

    assert capture.message_id == binding.user_message_id
    assert Repo.aggregate(Message, :count) == 1

    assert {:ok, replay} =
             Conversations.capture_canonical_message(
               facts,
               message("legacy-email-1"),
               source(config, %{source_scope: "INBOX"})
             )

    assert replay.message_id == capture.message_id

    assert {:error, :source_conflict} =
             Conversations.capture_canonical_message(
               facts,
               %{message("legacy-email-1") | role: "user"},
               source(config, %{
                 source_scope: "SENT",
                 existing_message_id: binding.user_message_id
               })
             )

    assert Repo.aggregate(TranscriptMessage, :count) == 1

    spoofed = %{
      incoming
      | message_id: "legacy-email-spoofed",
        routing_context: %{
          incoming.routing_context
          | audience: %{incoming.routing_context.audience | sender: "other@example.com"}
        }
    }

    assert {:error, :invalid_history_source} = Conversations.admit_incoming(spoofed)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(TranscriptMessage, :count) == 1
  end

  test "messages without a provider ID remain distinct on repeated passive capture" do
    sender = person("Unmentioned sender")
    config = connector("mattermost")
    facts = facts(config, sender, :channel)

    assert {:ok, first} =
             Conversations.capture_canonical_message(
               facts,
               Map.delete(message("ignored"), :external_message_id),
               source(config)
             )

    assert {:ok, second} =
             Conversations.capture_canonical_message(
               facts,
               Map.delete(message("ignored"), :external_message_id),
               source(config)
             )

    assert first.transcript_id == second.transcript_id
    assert first.message_id != second.message_id
    assert first.position == 1
    assert second.position == 2
  end

  test "a revoked direct participant grant is not reinstated by a duplicate delivery" do
    sender = person("Sender")
    peer = person("Peer")
    config = connector("mattermost")
    facts = facts(config, sender, :direct, %{recipient_person_ids: [peer.id]})

    assert {:ok, capture} =
             Conversations.capture_canonical_message(facts, message("dm-1"), source(config))

    resource = ChannelHistoryResource.for(config.provider, config.id, "room-1")

    provider_grant =
      Repo.get_by!(ResourcePermission,
        resource_type: elem(resource, 0),
        resource_id: elem(resource, 1),
        person_id: peer.id,
        source_key: "channel_history:participant"
      )

    assert :ok = Permissions.revoke(resource, provider_grant)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(peer, capture.transcript_id)

    assert {:ok, ^capture} =
             Conversations.capture_canonical_message(facts, message("dm-1"), source(config))

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(peer, capture.transcript_id)

    assert {:ok, next_message} =
             Conversations.capture_canonical_message(facts, message("dm-2"), source(config))

    assert next_message.transcript_id == capture.transcript_id

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(peer, capture.transcript_id)
  end

  test "direct thread reuses the same parent transcript without re-granting" do
    sender = person("Sender")
    peer = person("Peer")
    config = connector("mattermost")
    facts = facts(config, sender, :direct, %{recipient_person_ids: [peer.id]})

    assert {:ok, root} =
             Conversations.capture_canonical_message(facts, message("dm-root"), source(config))

    assert {:ok, thread} =
             Conversations.capture_canonical_message(
               %{facts | thread_id: "thread-1"},
               message("dm-reply"),
               source(config)
             )

    assert thread.transcript_id == root.transcript_id
    assert Repo.aggregate(Transcript, :count) == 1

    assert {:ok, [%{position: 1}, %{position: 2}]} =
             Conversations.list_canonical_messages(peer, thread.transcript_id)
  end

  test "direct participants get source-specific grants and a manual grant survives revocation" do
    sender = person("Sender")
    peer = person("Peer")
    outsider = person("Outsider")
    config = connector("mattermost")

    assert {:ok, capture} =
             Conversations.capture_canonical_message(
               facts(config, sender, :direct, %{recipient_person_ids: [peer.id]}),
               message("dm-1"),
               source(config)
             )

    assert {:ok, [_]} = Conversations.list_canonical_messages(sender, capture.transcript_id)
    assert {:ok, [_]} = Conversations.list_canonical_messages(peer, capture.transcript_id)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(outsider, capture.transcript_id)

    resource = ChannelHistoryResource.for(config.provider, config.id, "room-1")

    provider_grant =
      Repo.get_by!(ResourcePermission,
        resource_type: elem(resource, 0),
        resource_id: elem(resource, 1),
        person_id: peer.id,
        source_key: "channel_history:participant"
      )

    assert {:ok, _} = Permissions.grant(resource, %{person_id: peer.id, access_rights: ["read"]})
    assert :ok = Permissions.revoke(resource, provider_grant)
    assert {:ok, [_]} = Conversations.list_canonical_messages(peer, capture.transcript_id)
  end

  property "replicated capture deduplicates recipients but never invents a copy" do
    sender = person("Sender")
    first = person("First")
    second = person("Second")
    config = connector("email:imap")

    check all(
            recipients <- list_of(member_of([first.id, second.id]), max_length: 5),
            max_runs: 25
          ) do
      external_id = "email-#{System.unique_integer([:positive])}"

      assert {:ok, capture} =
               Conversations.capture_canonical_message(
                 facts(config, sender, :replicated, %{recipient_person_ids: recipients}),
                 message(external_id),
                 source(config, %{source_scope: "INBOX"})
               )

      assert Map.keys(capture.transcript_ids) |> Enum.sort() ==
               Enum.sort(Enum.uniq([sender.id | recipients]))

      assert Repo.aggregate(
               from(m in Message, where: m.external_message_id == ^external_id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(p in TranscriptMessage, where: p.message_id == ^capture.message_id),
               :count
             ) == length(Enum.uniq([sender.id | recipients]))
    end
  end
end
