defmodule Zaq.E2E.ChannelHistoryFixture do
  @moduledoc false

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, Transcript, TranscriptMessage}
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Permissions
  alias Zaq.Repo

  def seed! do
    config = config!()
    %{root: root, thread: thread, manual_person: manual_person} = shared_history!(config)
    replica = replicated_history!(config)
    legacy = legacy_history!()
    {viewer, viewer_password} = history_viewer!()

    %{
      shared_transcript_id: root.transcript_id,
      shared_message_id: root.message_id,
      thread_transcript_id: thread.transcript_id,
      thread_message_id: thread.message_id,
      thread_answer_id: thread.answer_id,
      manual_person_id: manual_person.id,
      replicated_transcript_id: replica.transcript_id,
      replicated_message_id: replica.message_id,
      replica_owner_name: replica.owner.full_name,
      legacy_transcript_id: legacy.transcript_id,
      legacy_message_id: legacy.message_id,
      viewer_username: viewer.username,
      viewer_password: viewer_password
    }
  end

  defp config! do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "E2E Mattermost History",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "e2e-history-token",
        enabled: true
      })
      |> Repo.insert!()

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(%{
      channel_config_id: config.id,
      channel_id: "e2eengineeringroom00000000",
      channel_name: "E2E Engineering",
      team_id: "e2e-team",
      team_name: "E2E Team",
      active: true
    })
    |> Repo.insert!()

    config
  end

  defp shared_history!(config) do
    alice = person!("E2E Alice")
    bob = person!("E2E Bob")
    manual_person = person!("E2E Manual Reader")
    add_channel!(alice, config, "e2e-alice")
    add_channel!(bob, config, "e2e-bob")

    root =
      incoming(config, alice, %{
        content: "Passive update retained without response",
        message_id: "e2e-root-message"
      })
      |> HistoryIngress.capture()
      |> ok!()

    thread =
      incoming(config, bob, %{
        content: "Thread follow-up",
        message_id: "e2e-thread-message",
        thread_id: "e2e-root-message"
      })
      |> HistoryIngress.capture()
      |> ok!()

    {:ok, thread_facts} =
      Facts.for_capture(%{
        provider: config.provider,
        channel_config_id: config.id,
        channel_id: "e2eengineeringroom00000000",
        kind: :channel,
        actor_person_id: alice.id,
        recipient_person_ids: [],
        thread_id: "e2e-root-message"
      })

    answer =
      Conversations.capture_canonical_message(
        thread_facts,
        %{
          role: "assistant",
          content: "Thread answer",
          external_message_id: "e2e-thread-answer"
        },
        %{
          provider: config.provider,
          channel_config_id: config.id,
          provenance: "provider_delivery"
        }
      )
      |> ok!()

    transcript = Repo.get!(Transcript, root.transcript_id)
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}

    Permissions.grant(resource, %{
      person_id: alice.id,
      source_key: "channel_history:provider:e2e",
      access_rights: ["read"]
    })
    |> ok!()

    Permissions.grant(resource, %{
      person_id: manual_person.id,
      source_key: "manual",
      access_rights: ["read"]
    })
    |> ok!()

    %{
      root: root,
      thread: Map.put(thread, :answer_id, answer.message_id),
      manual_person: manual_person
    }
  end

  defp replicated_history!(config) do
    survivor = person!("E2E Merged Recipient")
    loser = person!("E2E Previous Recipient")
    first_rater = person!("E2E Replica Rater One")
    second_rater = person!("E2E Replica Rater Two")

    {:ok, facts} =
      Facts.for_capture(%{
        provider: config.provider,
        channel_config_id: config.id,
        channel_id: "e2e-replicated-conversation",
        conversation_id: "e2e-replicated-conversation",
        kind: :replicated,
        actor_person_id: loser.id,
        recipient_person_ids: [],
        thread_id: nil
      })

    captured =
      Conversations.capture_canonical_message(
        facts,
        %{
          role: "assistant",
          content: "Recipient-specific answer",
          external_message_id: "e2e-replicated-answer",
          history_context: %{
            "author_person_id" => loser.id,
            "participants" => [%{"person_id" => loser.id, "role" => "recipient"}],
            "title_style" => "person"
          },
          attachments: [
            %{
              "id" => "invoice",
              "name" => "invoice.pdf",
              "mime_type" => "application/pdf",
              "size" => 2048
            }
          ]
        },
        %{
          provider: config.provider,
          channel_config_id: config.id,
          provenance: "provider_delivery",
          source_scope: "e2e-replica-scope"
        }
      )
      |> ok!()

    message = Repo.get!(Message, captured.message_id)
    Conversations.rate_message(message, %{person_id: first_rater.id, rating: 5}) |> ok!()
    Conversations.rate_message(message, %{person_id: second_rater.id, rating: 5}) |> ok!()
    People.merge_persons(survivor, loser) |> ok!()

    %{transcript_id: captured.transcript_id, message_id: message.id, owner: survivor}
  end

  defp legacy_history! do
    owner = person!("E2E Legacy Owner")

    conversation =
      Conversations.create_conversation(%{
        channel_type: "mattermost",
        person_id: owner.id,
        channel_user_id: "e2e-legacy-user",
        external_channel_id: "e2e-legacy-room"
      })
      |> ok!()

    message =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "assistant",
        content: "Legacy answer with preserved evidence",
        trace: [
          %{
            "id" => "e2e-legacy-trace",
            "type" => "tool_call",
            "name" => "legacy-search",
            "duration_ms" => 12
          }
        ]
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(
        attachments: [
          %{
            "id" => "legacy-report",
            "name" => "legacy-report.pdf",
            "mime_type" => "application/pdf",
            "size" => 4096
          }
        ]
      )
      |> Repo.update!()

    Conversations.rate_message(message, %{person_id: owner.id, rating: 5}) |> ok!()

    transcript =
      %Transcript{}
      |> Transcript.changeset(%{
        strategy: "legacy",
        provider: "legacy",
        scope_key: "legacy:#{conversation.id}",
        conversation_id: conversation.id,
        permission_resource_type: "legacy_conversation",
        permission_resource_id: conversation.id
      })
      |> Repo.insert!()

    %TranscriptMessage{}
    |> TranscriptMessage.changeset(%{
      transcript_id: transcript.id,
      message_id: message.id,
      position: 1,
      provenance: "legacy_restricted"
    })
    |> Repo.insert!()

    transcript |> Ecto.Changeset.change(next_position: 1) |> Repo.update!()
    %{transcript_id: transcript.id, message_id: message.id}
  end

  defp incoming(config, person, attrs) do
    Incoming.new(%{
      content: attrs.content,
      channel_id: "e2eengineeringroom00000000",
      provider: :mattermost,
      author_id: if(person.full_name == "E2E Alice", do: "e2e-alice", else: "e2e-bob"),
      author_name: person.full_name,
      message_id: attrs.message_id,
      thread_id: Map.get(attrs, :thread_id),
      is_dm: false,
      routing_context: %{
        channel_config_id: config.id,
        history_kind: :channel,
        identity_platform: "mattermost",
        source_scope: "e2eengineeringroom00000000"
      }
    })
  end

  defp person!(name), do: People.create_person(%{full_name: name}) |> ok!()

  defp add_channel!(person, config, identifier) do
    People.add_channel(%{
      person_id: person.id,
      platform: config.provider,
      channel_identifier: identifier,
      channel_config_id: config.id
    })
    |> ok!()
  end

  defp history_viewer! do
    username = "e2e_history_viewer"
    password = "StrongPass1!"

    case Accounts.get_user_by_username(username) do
      nil -> :ok
      user -> Repo.delete!(user)
    end

    {:ok, user} =
      Accounts.create_user_with_password(%{
        username: username,
        email: "#{username}@seed.local",
        role_id: Accounts.get_role_by_name("staff").id,
        password: password
      })

    user = user |> Ecto.Changeset.change(must_change_password: false) |> Repo.update!()
    {user, password}
  end

  defp ok!({:ok, value}), do: value
end
