defmodule Zaq.Engine.ChannelHistoryMembershipTest do
  use Zaq.DataCase, async: false

  alias Jido.Chat.Telegram.Adapter, as: TelegramAdapter
  alias Zaq.Accounts.People
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryMembership
  alias Zaq.Engine.{Conversations, HistoryIngress}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  @room "abcde12345abcde12345abcde1"

  defmodule SnapshotRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:membership_request, event})
      %{event | response: Process.get(:membership_response, {:error, :provider_down})}
    end
  end

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Membership connector",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, alice} = People.create_person(%{"full_name" => "Alice"})
    {:ok, bob} = People.create_person(%{"full_name" => "Bob"})

    for {person, identifier} <- [{alice, "alice"}, {bob, "bob"}] do
      {:ok, _} =
        People.add_channel(%{
          "person_id" => person.id,
          "platform" => "mattermost",
          "channel_identifier" => identifier,
          "channel_config_id" => config.id
        })
    end

    incoming =
      Incoming.new(%{
        content: "A room note",
        channel_id: @room,
        author_id: "alice",
        message_id: "post-1",
        provider: :mattermost,
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })

    {:ok, placement} = HistoryIngress.capture(incoming)
    %{config: config, alice: alice, bob: bob, placement: placement}
  end

  test "complete snapshots revoke only provider access, preserving manual access", ctx do
    %{config: config, alice: alice, bob: bob, placement: placement} = ctx
    resource = ChannelHistoryResource.for("mattermost", config.id, @room)
    assert {:ok, _} = Permissions.grant(resource, %{person_id: bob.id, access_rights: ["read"]})

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: ["alice", "bob"]}}
    )

    assert {:ok, %{members: 2}} =
             ChannelHistoryMembership.refresh(placement.transcript_id, router: SnapshotRouter)

    assert_received {:membership_request,
                     %Event{request: %{channel_config_id: id, channel_id: @room}}}

    assert id == config.id
    assert {:ok, [_]} = Conversations.list_canonical_messages(alice, placement.transcript_id)
    assert {:ok, [_]} = Conversations.list_canonical_messages(bob, placement.transcript_id)

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: []}}
    )

    assert {:ok, %{members: 0}} =
             ChannelHistoryMembership.refresh(placement.transcript_id, router: SnapshotRouter)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(alice, placement.transcript_id)

    assert {:ok, [_]} = Conversations.list_canonical_messages(bob, placement.transcript_id)

    assert Permissions.list_direct(resource) |> Enum.map(& &1.source_key) |> Enum.sort() == [
             "manual"
           ]
  end

  test "verified sender bootstraps inherited provider access once, never overriding removal",
       ctx do
    incoming = sender_message(ctx, "first-contact")
    assert {:ok, captured} = HistoryIngress.capture(incoming)
    assert {:ok, _} = Conversations.list_canonical_messages(ctx.alice, captured.transcript_id)
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, @room)

    assert [%{source_key: "channel_history:provider:mattermost"}] =
             Permissions.list_direct(resource)

    assert {:ok, _} = HistoryIngress.capture(incoming)
    assert length(Permissions.list_direct(resource)) == 1

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: []}}
    )

    assert {:ok, _} =
             ChannelHistoryMembership.refresh(captured.transcript_id, router: SnapshotRouter)

    for id <- ["first-contact", "later-post"] do
      assert {:ok, _} = HistoryIngress.capture(sender_message(ctx, id))

      assert {:error, :unauthorized} =
               Conversations.list_canonical_messages(ctx.alice, captured.transcript_id)
    end

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: ["alice"]}}
    )

    assert {:ok, _} =
             ChannelHistoryMembership.refresh(captured.transcript_id, router: SnapshotRouter)

    assert {:ok, _} = Conversations.list_canonical_messages(ctx.alice, captured.transcript_id)
  end

  test "sender observation cannot replace a missing, mismatched or inactive principal", ctx do
    for evidence <- [
          nil,
          %{identity_platform: "mattermost", member_id: "bob"},
          %{identity_platform: "other-server", member_id: "alice"}
        ] do
      incoming = sender_message(ctx, "invalid-#{inspect(evidence)}")

      incoming = %{
        incoming
        | routing_context: %{incoming.routing_context | sender_membership: evidence}
      }

      assert {:ok, _} = HistoryIngress.capture(incoming)

      assert {:error, :unauthorized} =
               Conversations.list_canonical_messages(ctx.alice, ctx.placement.transcript_id)
    end

    ctx.alice |> Ecto.Changeset.change(status: "inactive") |> Repo.update!()

    assert {:error, :invalid_sender_evidence} =
             ChannelHistoryMembership.observe_sender(
               ctx.placement.transcript_id,
               ctx.alice.id,
               %{identity_platform: "mattermost", member_id: "alice"}
             )
  end

  test "versioned removal fences first-contact evidence and manual access survives", ctx do
    assert {:ok, _} = HistoryIngress.capture(sender_message(ctx, "observed"))
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, @room)

    assert {:ok, _} =
             Permissions.grant(resource, %{person_id: ctx.alice.id, access_rights: ["read"]})

    event = %{
      provider: "mattermost",
      channel_config_id: ctx.config.id,
      channel_id: @room,
      identity_platform: "mattermost",
      member_id: "alice",
      operation: :remove,
      revision: 5
    }

    assert {:ok, _} = ChannelHistoryMembership.apply_event(event)
    assert {:ok, _} = HistoryIngress.capture(sender_message(ctx, "observed"))
    assert Enum.map(Permissions.list_direct(resource), & &1.source_key) == ["manual"]

    assert {:ok, _} =
             Conversations.list_canonical_messages(ctx.alice, ctx.placement.transcript_id)

    assert {:ok, _} =
             ChannelHistoryMembership.apply_event(%{event | operation: :add, revision: 6})

    assert length(Permissions.list_direct(resource)) == 2
  end

  defp sender_message(ctx, id) do
    Incoming.new(%{
      content: "Verified room sender",
      channel_id: @room,
      author_id: "alice",
      message_id: id,
      provider: :mattermost,
      routing_context: %{
        channel_config_id: ctx.config.id,
        conversation_type: :room,
        sender_membership: %{identity_platform: "mattermost", member_id: "alice"}
      }
    })
  end

  test "real Telegram normalization bootstraps a connector-local group author", ctx do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Telegram evidence",
        provider: "telegram",
        kind: "retrieval",
        enabled: true,
        url: "https://telegram.invalid",
        token: "test-token"
      })
      |> Repo.insert!()

    assert {:ok, _} =
             People.add_channel(%{
               person_id: ctx.alice.id,
               platform: "telegram",
               channel_identifier: "456",
               channel_config_id: config.id
             })

    payload = %{
      "message" => %{
        "message_id" => 42,
        "chat" => %{"id" => -123, "type" => "group"},
        "from" => %{"id" => 456},
        "text" => "@zaq legitimate question"
      }
    }

    assert {:ok, incoming} = TelegramAdapter.transform_incoming(payload)

    normalized =
      JidoChatBridge.to_internal(incoming, %{provider: :telegram, id: config.id})

    assert {:ok, captured} = HistoryIngress.capture(normalized)
    assert {:ok, [_]} = Conversations.list_canonical_messages(ctx.alice, captured.transcript_id)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(ctx.bob, captured.transcript_id)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(ctx.alice, ctx.placement.transcript_id)
  end

  test "Person refresh affects only that Person on the selected connector", ctx do
    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: ["alice", "bob"]}}
    )

    assert {:ok, _} =
             ChannelHistoryMembership.refresh(ctx.placement.transcript_id, router: SnapshotRouter)

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: []}}
    )

    assert {:ok, %{rooms: 1, members: 0}} =
             ChannelHistoryMembership.refresh_person(ctx.alice.id, ctx.config.id,
               router: SnapshotRouter
             )

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(ctx.alice, ctx.placement.transcript_id)

    assert {:ok, [_]} =
             Conversations.list_canonical_messages(ctx.bob, ctx.placement.transcript_id)
  end

  test "reordered membership events and snapshots cannot restore removed access", ctx do
    event = %{
      provider: "mattermost",
      channel_config_id: ctx.config.id,
      channel_id: @room,
      identity_platform: "mattermost",
      member_id: "alice",
      operation: :remove,
      revision: 20
    }

    assert {:ok, _} = ChannelHistoryMembership.apply_event(event)

    assert {:ok, %{status: :stale}} =
             ChannelHistoryMembership.apply_event(%{event | operation: :add, revision: 19})

    assert {:ok, %{status: :stale}} = ChannelHistoryMembership.apply_event(event)
    # Older events for another member still apply independently.
    assert {:ok, _} =
             ChannelHistoryMembership.apply_event(%{
               event
               | member_id: "bob",
                 operation: :add,
                 revision: 18
             })

    Process.put(
      :membership_response,
      {:ok,
       %{
         complete: true,
         identity_platform: "mattermost",
         revision: 19,
         member_ids: ["alice", "bob"]
       }}
    )

    assert {:ok, %{members: 1}} =
             ChannelHistoryMembership.refresh(ctx.placement.transcript_id, router: SnapshotRouter)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(ctx.alice, ctx.placement.transcript_id)

    assert {:ok, [_]} =
             Conversations.list_canonical_messages(ctx.bob, ctx.placement.transcript_id)

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: ["alice"]}}
    )

    assert {:error, :unordered_snapshot} =
             ChannelHistoryMembership.refresh(ctx.placement.transcript_id, router: SnapshotRouter)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(ctx.alice, ctx.placement.transcript_id)
  end

  test "removal revokes an inactive Person's provider grant before later reactivation", ctx do
    assert {:ok, _} =
             ChannelHistoryMembership.apply_event(%{
               provider: "mattermost",
               channel_config_id: ctx.config.id,
               channel_id: @room,
               identity_platform: "mattermost",
               member_id: "alice",
               operation: :add,
               revision: 19
             })

    assert {:ok, [_]} =
             Conversations.list_canonical_messages(ctx.alice, ctx.placement.transcript_id)

    inactive = ctx.alice |> Ecto.Changeset.change(status: "inactive") |> Repo.update!()

    assert {:ok, _} =
             ChannelHistoryMembership.apply_event(%{
               provider: "mattermost",
               channel_config_id: ctx.config.id,
               channel_id: @room,
               identity_platform: "mattermost",
               member_id: "alice",
               operation: :remove,
               revision: 20
             })

    active = inactive |> Ecto.Changeset.change(status: "active") |> Repo.update!()

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(active, ctx.placement.transcript_id)
  end

  test "incomplete and failed snapshots never remove provider grants", ctx do
    id = ctx.placement.transcript_id

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: ["alice"]}}
    )

    assert {:ok, _} = ChannelHistoryMembership.refresh(id, router: SnapshotRouter)

    for response <- [
          {:ok, %{complete: false, member_ids: []}},
          {:ok, %{member_ids: []}},
          {:error, :provider_down}
        ] do
      Process.put(:membership_response, response)
      assert {:error, _} = ChannelHistoryMembership.refresh(id, router: SnapshotRouter)
      assert {:ok, [_]} = Conversations.list_canonical_messages(ctx.alice, id)
    end
  end

  test "unknown members do not become People or gain grants, malformed result fails closed",
       ctx do
    id = ctx.placement.transcript_id

    Process.put(
      :membership_response,
      {:ok,
       %{
         complete: true,
         identity_platform: "mattermost",
         member_ids: ["stranger", "alice", "alice"]
       }}
    )

    assert {:ok, %{members: 1}} = ChannelHistoryMembership.refresh(id, router: SnapshotRouter)
    assert {:ok, [_]} = Conversations.list_canonical_messages(ctx.alice, id)

    Process.put(:membership_response, {:ok, %{complete: true, member_ids: [nil]}})

    assert {:error, :invalid_snapshot} =
             ChannelHistoryMembership.refresh(id, router: SnapshotRouter)

    assert {:ok, [_]} = Conversations.list_canonical_messages(ctx.alice, id)
  end

  test "malformed membership events fail closed without dispatch or changing access", ctx do
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, @room)

    before_state =
      Repo.get!(Zaq.Engine.Conversations.Transcript, ctx.placement.transcript_id).membership_state

    before_grants =
      Permissions.list_direct(resource) |> Enum.map(&{&1.person_id, &1.source_key}) |> Enum.sort()

    for event <- [
          %{},
          %{
            provider: "mattermost",
            channel_config_id: nil,
            channel_id: @room,
            identity_platform: "mattermost",
            member_id: "alice",
            operation: :add,
            revision: 1
          },
          %{
            provider: "mattermost",
            channel_config_id: ctx.config.id,
            channel_id: @room,
            identity_platform: "mattermost",
            member_id: "",
            operation: :add,
            revision: 1
          },
          %{
            provider: "mattermost",
            channel_config_id: ctx.config.id,
            channel_id: @room,
            identity_platform: "",
            member_id: "alice",
            operation: :add,
            revision: 1
          },
          %{
            provider: "mattermost",
            channel_config_id: ctx.config.id,
            channel_id: @room,
            identity_platform: "mattermost",
            member_id: String.duplicate("a", 256),
            operation: :add,
            revision: 1
          }
        ] do
      assert {:error, :invalid_membership_event} = ChannelHistoryMembership.apply_event(event)
    end

    refute_received {:membership_request, _}

    assert Repo.get!(Zaq.Engine.Conversations.Transcript, ctx.placement.transcript_id).membership_state ==
             before_state

    assert Permissions.list_direct(resource)
           |> Enum.map(&{&1.person_id, &1.source_key})
           |> Enum.sort() == before_grants
  end

  test "invalid ordered events roll back membership state and grants", ctx do
    event = %{
      provider: "mattermost",
      channel_config_id: ctx.config.id,
      channel_id: @room,
      identity_platform: "mattermost",
      member_id: "alice",
      operation: :invalid,
      revision: 1
    }

    before_state =
      Repo.get!(Zaq.Engine.Conversations.Transcript, ctx.placement.transcript_id).membership_state

    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, @room)

    before_grants =
      Permissions.list_direct(resource) |> Enum.map(&{&1.person_id, &1.source_key}) |> Enum.sort()

    assert {:error, :invalid_membership_event} = ChannelHistoryMembership.apply_event(event)

    assert Repo.get!(Zaq.Engine.Conversations.Transcript, ctx.placement.transcript_id).membership_state ==
             before_state

    assert Permissions.list_direct(resource)
           |> Enum.map(&{&1.person_id, &1.source_key})
           |> Enum.sort() == before_grants
  end

  test "disabled connector rejects membership refresh without dispatch", ctx do
    config = ctx.config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    resource = ChannelHistoryResource.for("mattermost", config.id, @room)

    assert {:ok, _} =
             Permissions.grant(resource, %{person_id: ctx.bob.id, access_rights: ["read"]})

    before_grants =
      Permissions.list_direct(resource) |> Enum.map(&{&1.person_id, &1.source_key}) |> Enum.sort()

    assert {:error, :unsupported_membership_refresh} =
             ChannelHistoryMembership.refresh(ctx.placement.transcript_id, router: SnapshotRouter)

    refute_received {:membership_request, _}

    assert Enum.map(Permissions.list_direct(resource), &{&1.person_id, &1.source_key}) ==
             before_grants
  end

  test "invalid and oversized member snapshots preserve existing access", ctx do
    id = ctx.placement.transcript_id
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, @room)

    Process.put(
      :membership_response,
      {:ok, %{complete: true, identity_platform: "mattermost", member_ids: ["alice"]}}
    )

    assert {:ok, _} = ChannelHistoryMembership.refresh(id, router: SnapshotRouter)
    before_state = Repo.get!(Zaq.Engine.Conversations.Transcript, id).membership_state
    before_grants = Enum.map(Permissions.list_direct(resource), &{&1.person_id, &1.source_key})

    for member_ids <- [nil, %{}, Enum.map(1..10_001, &"unknown-#{&1}")] do
      Process.put(
        :membership_response,
        {:ok, %{complete: true, identity_platform: "mattermost", member_ids: member_ids}}
      )

      assert {:error, :invalid_snapshot} =
               ChannelHistoryMembership.refresh(id, router: SnapshotRouter)

      assert {:ok, [_]} = Conversations.list_canonical_messages(ctx.alice, id)
      assert Repo.get!(Zaq.Engine.Conversations.Transcript, id).membership_state == before_state

      assert Permissions.list_direct(resource)
             |> Enum.map(&{&1.person_id, &1.source_key})
             |> Enum.sort() == before_grants
    end
  end

  test "unknown well-formed event records evidence without creating a Person or grant", ctx do
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, @room)
    before_people = Repo.aggregate(Zaq.Accounts.Person, :count)

    before_grants =
      Permissions.list_direct(resource) |> Enum.map(&{&1.person_id, &1.source_key}) |> Enum.sort()

    assert {:ok, %{status: :applied}} =
             ChannelHistoryMembership.apply_event(%{
               provider: "mattermost",
               channel_config_id: ctx.config.id,
               channel_id: @room,
               identity_platform: "mattermost",
               member_id: "unknown-member",
               operation: :add,
               revision: 1
             })

    assert Repo.get!(Zaq.Engine.Conversations.Transcript, ctx.placement.transcript_id).membership_state ==
             %{
               "events" => %{"unknown-member" => %{"present" => true, "revision" => 1}},
               "members" => ["unknown-member"],
               "platform" => "mattermost"
             }

    assert Repo.aggregate(Zaq.Accounts.Person, :count) == before_people

    assert Permissions.list_direct(resource)
           |> Enum.map(&{&1.person_id, &1.source_key})
           |> Enum.sort() == before_grants
  end
end
