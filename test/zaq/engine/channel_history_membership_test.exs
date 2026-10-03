defmodule Zaq.Engine.ChannelHistoryMembershipTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
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
        routing_context: %{channel_config_id: config.id, history_kind: :channel}
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
    assert Enum.map(Permissions.list_direct(resource), & &1.source_key) == ["manual"]
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
end
