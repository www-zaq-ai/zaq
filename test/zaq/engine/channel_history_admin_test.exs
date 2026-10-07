defmodule Zaq.Engine.ChannelHistoryAdminTest do
  use Zaq.DataCase, async: false

  import Zaq.AccountsFixtures

  alias Zaq.Accounts.People
  alias Zaq.Engine.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, MessageRating}
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  setup do
    admin = super_admin_fixture()
    regular = user_fixture()
    {:ok, person} = People.create_person(%{"full_name" => "Alex"})

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Admin history",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, _} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "mattermost",
        "channel_identifier" => "alex",
        "channel_config_id" => config.id
      })

    incoming =
      Incoming.new(%{
        content: "hello",
        channel_id: "room",
        provider: :mattermost,
        author_id: "alex",
        message_id: "m1",
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })

    {:ok, captured} = HistoryIngress.capture(incoming)
    %{admin: admin, regular: regular, person: person, config: config, captured: captured}
  end

  defp request(user, req) do
    Event.new(req, :engine,
      actor: %{user_id: user.id},
      opts: [action: :channel_history_admin, confidential: true]
    )
    |> then(&Api.handle_event(&1, :channel_history_admin, %{}))
    |> Map.get(:response)
  end

  def count_query(_event, _measurements, _metadata, owner) do
    if self() == owner, do: send(owner, :history_projection_query)
  end

  defp query_count(fun) do
    handler = "history-projection-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:zaq, :repo, :query], &__MODULE__.count_query/4, self())

    try do
      result = fun.()
      {result, drain_query_count(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_query_count(count) do
    receive do
      :history_projection_query -> drain_query_count(count + 1)
    after
      0 -> count
    end
  end

  test "current super-admin lists and reads only a public bounded projection", %{
    admin: admin,
    config: config,
    captured: captured
  } do
    assert {:ok, [row]} = request(admin, %{op: :list})
    assert row.id == captured.transcript_id
    assert row.channel_config_id == config.id
    refute Map.has_key?(row, :metadata)

    assert {:ok, %{messages: [%{content: "hello"}], grants: []}} =
             request(admin, %{op: :detail, id: row.id, cursor: 0})

    assert {:error, :not_found} = request(admin, %{op: :detail, id: "unknown", cursor: 0})
  end

  test "admin can page actual transcripts instead of losing everything beyond the first 50", %{
    admin: admin,
    config: config
  } do
    for channel <- ["room-2", "room-3"] do
      assert {:ok, _} =
               HistoryIngress.capture(
                 Incoming.new(%{
                   content: channel,
                   channel_id: channel,
                   author_id: "alex",
                   message_id: "message-#{channel}",
                   provider: :mattermost,
                   routing_context: %{channel_config_id: config.id, conversation_type: :room}
                 })
               )
    end

    assert {:ok, %{rows: first, has_more: true}} =
             request(admin, %{op: :list, limit: 2, offset: 0})

    assert {:ok, %{rows: last, has_more: false}} =
             request(admin, %{op: :list, limit: 2, offset: 2})

    assert length(first) == 2
    assert length(last) == 1
    assert MapSet.size(MapSet.new(Enum.map(first ++ last, & &1.id))) == 3
    assert {:error, :invalid_request} = request(admin, %{op: :list, offset: -1})
  end

  test "list query budget is constant across populated page sizes", ctx do
    {{:ok, [_]}, one_count} = query_count(fn -> request(ctx.admin, %{op: :list}) end)

    for index <- 2..10 do
      assert {:ok, _} = capture(ctx, "room-#{index}", "message-#{index}", "external")
    end

    {{:ok, rows}, ten_count} = query_count(fn -> request(ctx.admin, %{op: :list}) end)

    assert length(rows) == 10
    assert one_count <= 12
    assert ten_count == one_count
  end

  test "empty thread pages retain authorized parent context and reject nonexistent parents",
       ctx do
    assert {:ok, %{rows: [], parent: parent}} =
             request(
               ctx.admin,
               %{op: :list, parent_id: ctx.captured.transcript_id, offset: 50}
             )

    assert parent.id == ctx.captured.transcript_id
    assert parent.channel_name == "Admin history"

    assert {:error, :not_found} =
             request(
               ctx.admin,
               %{op: :list, parent_id: Ecto.UUID.generate(), offset: 0}
             )

    assert {:error, :unauthorized} =
             request(
               ctx.regular,
               %{op: :list, parent_id: ctx.captured.transcript_id, offset: 0}
             )
  end

  test "message cursor advances beyond the first page without repeating messages", ctx do
    for index <- 2..51 do
      assert {:ok, _} = capture(ctx, "room", "post-#{index}", "external")
    end

    assert {:ok, %{messages: first}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})

    assert length(first) == 50

    assert {:ok, %{messages: [last]}} =
             request(ctx.admin, %{
               op: :detail,
               id: ctx.captured.transcript_id,
               cursor: List.last(first).position
             })

    assert last.position == 51
    refute last.message_id in Enum.map(first, & &1.message_id)

    assert {:ok, %{messages: []}} =
             request(ctx.admin, %{
               op: :detail,
               id: ctx.captured.transcript_id,
               cursor: last.position
             })
  end

  test "message information and feedback require a current admin and the exact placement", ctx do
    {:ok, answer} = capture(ctx, "room", "answer", "assistant")
    {:ok, other} = capture(ctx, "other-room", "other", "external")

    Repo.get!(Message, answer.message_id)
    |> Ecto.Changeset.change(model: "model-test", metadata: %{"agent" => "Support Agent"})
    |> Repo.update!()

    info = %{op: :message_info, id: answer.transcript_id, message_id: answer.message_id}

    rating = %{
      op: :rate,
      id: answer.transcript_id,
      message_id: answer.message_id,
      rating: 5,
      actor: %{user_id: ctx.regular.id}
    }

    assert {:ok, %{model: "model-test"}} = request(ctx.admin, info)
    assert {:error, :unauthorized} = request(ctx.regular, info)
    assert {:error, :unauthorized} = request(ctx.regular, rating)
    assert {:error, :not_found} = request(ctx.admin, %{info | id: other.transcript_id})
    assert {:error, :not_found} = request(ctx.admin, %{rating | id: other.transcript_id})

    assert {:error, :not_found} =
             request(ctx.admin, %{rating | message_id: ctx.captured.message_id})

    assert {:ok, saved} = request(ctx.admin, rating)
    assert saved.user_id == ctx.admin.id
    assert saved.message_id == answer.message_id
    assert {:ok, updated} = request(ctx.admin, %{rating | rating: 1})
    assert updated.id == saved.id
    assert Repo.aggregate(MessageRating, :count) == 1

    assert {:ok, %{messages: messages}} =
             request(ctx.admin, %{op: :detail, id: answer.transcript_id})

    assert Enum.find(messages, &(&1.message_id == answer.message_id)).feedback == :negative
    assert Enum.find(messages, &(&1.message_id == ctx.captured.message_id)).display_name == "Alex"
    refute Enum.any?(messages, &(Map.has_key?(&1, :metadata) or Map.has_key?(&1, :trace)))
  end

  defp capture(ctx, room, external_id, role) do
    {:ok, facts} =
      Facts.new(%{
        provider: "mattermost",
        channel_config_id: ctx.config.id,
        channel_id: room,
        kind: :channel,
        actor_person_id: ctx.person.id
      })

    Conversations.capture_canonical_message(
      facts,
      %{role: role, content: external_id, external_message_id: external_id, author_id: "alex"},
      %{provider: "mattermost", channel_config_id: ctx.config.id, provenance: "provider_event"}
    )
  end

  test "channel list groups threads and detail presents the stored root before replies", ctx do
    {:ok, facts} =
      Facts.for_capture(%{
        provider: "mattermost",
        channel_config_id: ctx.config.id,
        channel_id: "room",
        kind: :channel,
        actor_person_id: ctx.person.id,
        thread_id: "m1"
      })

    {:ok, thread} =
      Conversations.capture_canonical_message(
        facts,
        %{role: "external", content: "reply", external_message_id: "reply", author_id: "alex"},
        %{provider: "mattermost", channel_config_id: ctx.config.id, provenance: "provider_event"}
      )

    assert {:ok, [channel]} = request(ctx.admin, %{op: :list})
    assert channel.thread_count == 1
    assert channel.participant_count == 1
    assert [%{person_id: person_id}] = channel.participants
    assert person_id == ctx.person.id
    assert {:ok, [row]} = request(ctx.admin, %{op: :list, parent_id: channel.id})
    assert row.id == thread.transcript_id
    assert row.root_message.content == "hello"

    assert {:ok, %{root_message: root, messages: [reply]}} =
             request(ctx.admin, %{op: :detail, id: thread.transcript_id})

    assert root.message_id == ctx.captured.message_id
    assert reply.content == "reply"
    assert root.person_id == ctx.person.id
  end

  test "participants are distinct People ordered by their most recent contribution", ctx do
    people =
      for index <- 1..4 do
        {:ok, person} = People.create_person(%{full_name: "Participant #{index}"})

        {:ok, _} =
          People.add_channel(%{
            person_id: person.id,
            platform: "mattermost",
            channel_identifier: "author-#{index}",
            channel_config_id: ctx.config.id
          })

        {:ok, captured} =
          HistoryIngress.capture(
            Incoming.new(%{
              content: "message",
              provider: :mattermost,
              channel_id: "room",
              author_id: "author-#{index}",
              message_id: "participant-#{index}",
              routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
            })
          )

        Repo.get!(Message, captured.message_id)
        |> Ecto.Changeset.change(
          provider_sent_at: DateTime.add(DateTime.utc_now(), index, :second)
        )
        |> Repo.update!()

        person
      end

    assert {:ok, [row]} = request(ctx.admin, %{op: :list})
    assert row.participant_count == 5

    assert Enum.map(row.participants, & &1.person_id) ==
             people |> Enum.reverse() |> Enum.take(3) |> Enum.map(& &1.id)
  end

  test "participant timestamp ties are ordered by Person ID and assistant messages are excluded",
       ctx do
    timestamp = ~U[2026-01-01 12:00:00.000000Z]

    Repo.get!(Message, ctx.captured.message_id)
    |> Ecto.Changeset.change(provider_sent_at: timestamp)
    |> Repo.update!()

    people =
      for index <- 1..4 do
        {:ok, person} = People.create_person(%{full_name: "Tied participant #{index}"})

        {:ok, facts} =
          Facts.for_capture(%{
            provider: "mattermost",
            channel_config_id: ctx.config.id,
            channel_id: "room",
            kind: :channel,
            actor_person_id: person.id
          })

        {:ok, _} =
          Conversations.capture_canonical_message(
            facts,
            %{
              role: if(index == 4, do: "assistant", else: "external"),
              content: "tied contribution",
              external_message_id: "tie-#{index}",
              provider_sent_at: timestamp,
              history_context: %{
                "author_person_id" => person.id,
                "participants" => [%{"person_id" => person.id, "role" => "sender"}]
              }
            },
            %{
              provider: "mattermost",
              channel_config_id: ctx.config.id,
              provenance: "provider_event"
            }
          )

        person
      end

    assert {:ok, [row]} = request(ctx.admin, %{op: :list})
    assert row.participant_count == 4

    assert Enum.map(row.participants, & &1.person_id) ==
             [ctx.person | Enum.take(people, 3)]
             |> Enum.map(& &1.id)
             |> Enum.sort()
             |> Enum.take(3)
  end

  test "participant evidence resolves merged identities without counting the survivor twice",
       ctx do
    old_id = ctx.person.id + 1_000_000

    ctx.person
    |> Ecto.Changeset.change(merged_person_ids: [old_id])
    |> Repo.update!()

    Repo.get!(Message, ctx.captured.message_id)
    |> Ecto.Changeset.change(
      history_context: %{
        "author_person_id" => old_id,
        "participants" => [
          %{"person_id" => old_id, "role" => "sender"},
          %{"person_id" => ctx.person.id, "role" => "to"}
        ]
      }
    )
    |> Repo.update!()

    assert {:ok, [row]} = request(ctx.admin, %{op: :list})
    assert row.participant_count == 1
    assert [%{person_id: person_id, display_name: "Alex"}] = row.participants
    assert person_id == ctx.person.id
  end

  test "staff and missing actor cannot enumerate or read histories", %{
    regular: staff,
    captured: captured
  } do
    assert {:error, :unauthorized} = request(staff, %{op: :list})
    assert {:error, :unauthorized} = request(staff, %{op: :detail, id: captured.transcript_id})
    assert {:error, :unauthorized} = request(staff, %{op: :refresh, id: captured.transcript_id})

    event =
      Event.new(%{op: :list}, :engine, opts: [action: :channel_history_admin, confidential: true])

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(event, :channel_history_admin, %{})
  end

  test "unsupported room identifiers cannot trigger provider IO", %{
    admin: admin,
    captured: captured
  } do
    assert {:error, :unsupported} =
             request(admin, %{op: :refresh, id: captured.transcript_id})
  end

  test "confidential routing is mandatory even for super-admin", %{admin: admin} do
    event =
      Event.new(%{op: :list}, :engine,
        actor: %{user_id: admin.id},
        opts: [action: :channel_history_admin]
      )

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(event, :channel_history_admin, %{})
  end

  test "manual grant and revocation change Person reads without touching provider grants", %{
    admin: admin,
    captured: captured
  } do
    {:ok, reader} = People.create_person(%{"full_name" => "Reader"})

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    assert {:ok, _} =
             request(admin, %{op: :grant, id: captured.transcript_id, person_id: reader.id})

    assert {:ok, [%{content: "hello"}]} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    assert {:ok, %{grants: [%{source: "manual", person_id: id}]}} =
             request(admin, %{op: :detail, id: captured.transcript_id})

    assert id == reader.id

    assert {:ok, :revoked} =
             request(admin, %{op: :revoke, id: captured.transcript_id, person_id: reader.id})

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(reader, captured.transcript_id)

    assert {:error, :invalid_person} =
             request(admin, %{op: :grant, id: captured.transcript_id, person_id: 99_999_999})
  end
end
