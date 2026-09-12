defmodule Zaq.Accounts.PersonMergeTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Agent.Tools.Resources.QueryResources
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.PeopleGateway
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, DocumentAccess}
  alias Zaq.People.IdentityResolver
  alias Zaq.Permissions
  alias Zaq.Permissions.{PermissionRevokerMock, ResourcePermission}

  import Mox
  import Zaq.SystemConfigFixtures, only: [ai_credential_fixture: 0]
  setup :verify_on_exit!

  setup context do
    if context[:legacy_channels] do
      # Serial sandbox DDL restores the pre-index migration schema only inside
      # this transaction. Rollback restores the global index for other tests.
      Repo.query!("DROP INDEX IF EXISTS channels_platform_channel_identifier_index")

      Repo.query!(
        "CREATE UNIQUE INDEX IF NOT EXISTS channels_person_id_platform_channel_identifier_index ON channels (person_id, platform, channel_identifier)"
      )
    end

    :ok
  end

  for {winner_identifier, duplicate_identifier} <- [
        {"\u2003ÄLİCE@EXAMPLE.COM ", "äli̇ce@example.com"},
        {"äli̇ce@example.com", "\u2003ÄLİCE@EXAMPLE.COM "}
      ] do
    @winner_identifier winner_identifier
    @duplicate_identifier duplicate_identifier
    @tag :legacy_channels
    test "legacy email merge preserves survivor winner #{inspect(winner_identifier)} and original history" do
      loser = legacy(nil, " ")
      third = legacy(nil, "Third")
      survivor = legacy(nil, @winner_identifier)
      # Raw rows reproduce legacy case variants that new changesets must reject.
      duplicate =
        Repo.insert!(%PersonChannel{
          person_id: loser.id,
          platform: "email",
          channel_identifier: @duplicate_identifier,
          weight: 0,
          display_name: "Discarded",
          phone: "123",
          metadata: %{"nested" => %{"keep" => true, "fill" => "filled"}},
          last_interaction_at: ~U[2026-02-01 00:00:00Z]
        })

      winner =
        Repo.insert!(%PersonChannel{
          person_id: survivor.id,
          platform: "email",
          channel_identifier: @winner_identifier,
          weight: 7,
          display_name: "Kept",
          metadata: %{"nested" => %{"keep" => false, "fill" => " "}},
          last_interaction_at: ~U[2026-01-01 00:00:00Z]
        })

      same_person_duplicate =
        Repo.insert!(%PersonChannel{
          person_id: survivor.id,
          platform: "email",
          channel_identifier: @duplicate_identifier,
          weight: 1
        })

      extra =
        Repo.insert!(%PersonChannel{
          person_id: third.id,
          platform: "email",
          channel_identifier: "ÄLİCE@example.com",
          metadata: %{"third" => 3},
          last_interaction_at: ~U[2026-03-01 00:00:00Z]
        })

      opaque =
        Repo.insert!(%PersonChannel{
          person_id: loser.id,
          platform: "slack",
          channel_identifier: @duplicate_identifier,
          weight: 9
        })

      assert {:ok, merged} = People.merge_persons(survivor, [third, loser])
      assert [email] = Enum.filter(merged.channels, &(&1.platform == "email"))
      assert email.id == winner.id
      assert email.weight == 7
      assert email.channel_identifier == "äli̇ce@example.com"
      assert email.display_name == "Kept"
      assert email.phone == "123"
      assert email.metadata == %{"nested" => %{"keep" => false, "fill" => "filled"}, "third" => 3}
      assert email.last_interaction_at == ~U[2026-03-01 00:00:00Z]
      assert merged.full_name == "Third"

      assert Enum.find(merged.merge_history, &(&1["id"] == loser.id))["label"] ==
               @duplicate_identifier

      assert People.get_channel(opaque.id).channel_identifier == @duplicate_identifier

      for removed <- [duplicate, same_person_duplicate, extra],
          do: assert(People.get_channel(removed.id) == nil)
    end
  end

  test "email group without a survivor channel reparents the original lowest-person winner" do
    survivor = legacy(nil, "Survivor")
    first = legacy(nil, "First")
    second = legacy(nil, "Second")

    later =
      Repo.insert!(%PersonChannel{
        person_id: second.id,
        platform: "email",
        channel_identifier: "reparent@example.com"
      })

    winner =
      Repo.insert!(%PersonChannel{
        person_id: first.id,
        platform: "email",
        channel_identifier: " REPARENT@EXAMPLE.COM ",
        weight: 8
      })

    assert {:ok, merged} = People.merge_persons(survivor, [second, first])
    assert [channel] = merged.channels
    assert channel.id == winner.id
    assert channel.person_id == survivor.id
    assert channel.weight == 8
    assert channel.channel_identifier == "reparent@example.com"
    assert channel.last_interaction_at == nil
    assert People.get_channel(later.id) == nil
  end

  test "invalid routing prevents all writes including canonical channel deduplication" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")

    winner =
      Repo.insert!(%PersonChannel{
        person_id: survivor.id,
        platform: "email",
        channel_identifier: " ROLLBACK@example.com ",
        metadata: %{"kept" => 1}
      })

    duplicate =
      Repo.insert!(%PersonChannel{
        person_id: survivor.id,
        platform: "email",
        channel_identifier: "rollback@example.com"
      })

    moved =
      Repo.insert!(%PersonChannel{
        person_id: loser.id,
        platform: "email",
        channel_identifier: "Rollback@example.com",
        last_interaction_at: ~U[2026-03-01 00:00:00Z]
      })

    rule = Repo.insert!(%IncomingMessageRoutingRule{person_id: loser.id, routing_mode: :agent})
    capture_writes()
    assert {:error, changeset} = People.merge_persons(survivor, loser)
    refute_received {:merge_write, _, _}
    assert errors_on(changeset).configured_agent_id == ["can't be blank"]

    for original <- [winner, duplicate, moved],
        do: assert(People.get_channel(original.id) == original)

    assert Repo.get!(IncomingMessageRoutingRule, rule.id) == rule
    assert Repo.get!(Person, survivor.id) == survivor
    assert Repo.get!(Person, loser.id) == loser
  end

  property "multi-loser resource and principal collisions union rights without team leakage" do
    check all(reversed <- boolean(), max_runs: 6) do
      survivor = legacy(nil, "Survivor")
      first = legacy(nil, "First")
      second = legacy(nil, "Second")
      outsider = legacy(nil, "Unaffected")
      {:ok, team} = People.create_team(%{name: "Collision team #{survivor.id}"})
      {:ok, _} = Permissions.grant(survivor, %{person_id: survivor.id, access_rights: ["manage"]})
      {:ok, _} = Permissions.grant(survivor, %{team_id: team.id, access_rights: ["view"]})

      {:ok, _} =
        Permissions.grant(first, %{
          person_id: second.id,
          team_id: team.id,
          access_rights: ["read"]
        })

      {:ok, _} = Permissions.grant(second, %{person_id: first.id, access_rights: ["write"]})

      {:ok, untouched} =
        Permissions.grant(outsider, %{person_id: outsider.id, access_rights: ["delete"]})

      losers = if reversed, do: [second, first], else: [first, second]

      assert {:ok, _} = People.merge_persons(survivor, losers)
      grants = Permissions.list(survivor)
      assert length(grants) == 2
      person_grant = Enum.find(grants, &(&1.person_id == survivor.id))
      team_grant = Enum.find(grants, &(&1.team_id == team.id))
      assert person_grant.team_id == nil
      assert person_grant.access_rights == ["manage", "read", "write"]
      assert team_grant.person_id == nil
      assert team_grant.access_rights == ["read", "view"]
      assert Repo.get!(ResourcePermission, untouched.id) == untouched
    end
  end

  test "principal collisions on other resources preserve independent team rights" do
    survivor = legacy(nil, "Survivor")
    first = legacy(nil, "First")
    second = legacy(nil, "Second")
    {:ok, team} = People.create_team(%{name: "Document team"})
    resource = %Zaq.Ingestion.Document{id: 42}
    {:ok, _} = Permissions.grant(resource, %{person_id: survivor.id, access_rights: ["manage"]})

    {:ok, _} =
      Permissions.grant(resource, %{
        person_id: first.id,
        team_id: team.id,
        access_rights: ["read"]
      })

    {:ok, _} = Permissions.grant(resource, %{person_id: second.id, access_rights: ["write"]})

    assert {:ok, _} = People.merge_persons(survivor, [second, first])
    grants = Permissions.list(resource)
    assert length(grants) == 2

    assert Enum.any?(
             grants,
             &(&1.person_id == survivor.id and is_nil(&1.team_id) and
                 &1.access_rights == ["manage", "read", "write"])
           )

    assert Enum.any?(
             grants,
             &(is_nil(&1.person_id) and &1.team_id == team.id and &1.access_rights == ["read"])
           )
  end

  test "grant validation failure prevents all writes to originals and merged channels" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")

    {:ok, channel} =
      People.add_channel(%{
        person_id: loser.id,
        platform: "slack",
        channel_identifier: "grant-rollback"
      })

    {:ok, valid} = Permissions.grant(survivor, %{person_id: survivor.id, access_rights: ["read"]})

    invalid =
      Repo.insert!(%ResourcePermission{
        resource_type: "person",
        resource_id: to_string(loser.id),
        person_id: loser.id,
        access_rights: ["invalid"]
      })

    capture_writes()
    assert {:error, changeset} = People.merge_persons(survivor, loser)
    refute_received {:merge_write, _, _}
    assert errors_on(changeset).access_rights == ["has an invalid entry"]
    assert Repo.get!(ResourcePermission, valid.id) == valid
    assert Repo.get!(ResourcePermission, invalid.id) == invalid
    assert People.get_channel(channel.id).person_id == loser.id
    assert People.get_person(loser.id).id == loser.id
    assert People.get_person(survivor.id).merged_person_ids == []
  end

  test "revoke failure after a deletion restores exact originals and identity" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")
    {:ok, first} = Permissions.grant(survivor, %{person_id: survivor.id, access_rights: ["read"]})
    {:ok, second} = Permissions.grant(loser, %{person_id: loser.id, access_rights: ["write"]})
    changeset = Ecto.Changeset.change(second) |> Ecto.Changeset.add_error(:base, "cannot revoke")

    expect(PermissionRevokerMock, :delete, fn permission ->
      assert permission.id == first.id
      Repo.delete(permission)
    end)

    expect(PermissionRevokerMock, :delete, fn permission ->
      assert permission.id == second.id
      {:error, changeset}
    end)

    assert {:error, ^changeset} =
             People.merge_persons(survivor, loser, revoker: PermissionRevokerMock)

    assert Repo.get!(ResourcePermission, first.id) == first
    assert Repo.get!(ResourcePermission, second.id) == second
    assert People.get_person(loser.id).id == loser.id
    assert People.get_person(survivor.id).merged_person_ids == []
  end

  property "group order and repeated losers preserve the explicit profile and union of teams" do
    check all(
            teams <- list_of(integer(10..100), max_length: 5),
            reversed <- boolean(),
            max_runs: 12
          ) do
      survivor = legacy(nil, "Explicit")
      first = legacy(nil, "First") |> Ecto.Changeset.change(team_ids: teams) |> Repo.update!()
      last = legacy(nil, "Last") |> Ecto.Changeset.change(team_ids: nil) |> Repo.update!()
      losers = if reversed, do: [last, first, first], else: [first, last, first]
      assert {:ok, merged} = People.merge_persons(survivor, losers)
      assert merged.full_name == "Explicit"
      assert MapSet.new(merged.team_ids) == MapSet.new(teams)
      assert Enum.map(merged.merge_history, & &1["id"]) == [first.id, last.id]
    end
  end

  test "admin gateway exposes merge history and old IDs return canonical identity" do
    a = legacy("old@example.com", "Previous Name")
    b = legacy("kept@example.com", "Selected Survivor")

    assert {:ok, _} =
             PeopleGateway.dispatch(:merge, %{survivor_id: b.id, loser_id: a.id})

    assert {:ok, person} = PeopleGateway.dispatch(:get, %{id: to_string(a.id)})
    assert person.id == b.id
    assert [entry] = person.merge_history
    assert entry["id"] == a.id
    assert entry["label"] == "Previous Name"
    assert Map.keys(entry) |> Enum.sort() == ["id", "label", "merged_at"]
    assert {:ok, _, 0} = DateTime.from_iso8601(entry["merged_at"])
  end

  test "group merge frees all three emails, retains identity history and resolves flat chains" do
    a = legacy(" A@EXAMPLE.COM ", "First")
    b = legacy("A@example.com", "Second")
    c = legacy("a@example.com", "Third")

    capture_writes()
    assert {:ok, survivor} = People.merge_persons(b, [c, a])
    assert_received {:merge_write, "UPDATE \"people\"" <> query, params}
    assert query =~ "merged_person_ids"
    assert query =~ "merge_history"
    assert query =~ "email"
    assert List.last(params) == b.id
    refute_received {:merge_write, "UPDATE \"people\"" <> _, _}
    assert survivor.id == b.id
    assert survivor.email == "a@example.com"
    assert survivor.full_name == "Second"
    assert People.get_person(a.id).id == b.id
    assert People.get_person!(c.id).id == b.id
    refute Repo.get(Person, a.id)
    refute Repo.get(Person, c.id)
    assert Enum.sort(survivor.merged_person_ids) == [a.id, c.id]
    assert Enum.map(People.list_people(), & &1.id) == [b.id]
    assert {[_], 1} = People.filter_people(%{})
    assert People.search_people("First") == []
    assert Enum.map(People.list_incomplete(), & &1.id) == [b.id]

    d = legacy("new@example.com", "Last")
    assert {:ok, _} = People.merge_persons(d.id, b.id)

    for old <- [a, b, c] do
      assert People.get_person(old.id).id == d.id
      refute Repo.get(Person, old.id)
    end

    assert length(People.get_person!(d.id).merge_history) == 3
    assert {:error, :self_merge} = People.merge_persons(a.id, d.id)
    assert {:ok, _} = People.delete_person(d)
    for old <- [a, b, c, d], do: assert(People.get_person(old.id) == nil)
  end

  test "hard deletion forgets new IDs but preserves inherited aliases and their history" do
    a = legacy(nil, "A")
    b = legacy(nil, "B")
    c = legacy(nil, "C")
    assert {:ok, _} = People.merge_persons(b, a)
    history = People.get_person!(b.id).merge_history
    assert {:ok, _} = People.merge_persons(c, [b], retain_redirect: false)
    refute Repo.get(Person, b.id)
    assert People.get_person(a.id).id == c.id
    assert People.get_person(b.id) == nil
    assert People.get_person(c.id).merged_person_ids == [a.id]
    assert People.get_person!(c.id).merge_history == history
  end

  test "invalid group and a nested failure roll back original profile and channels" do
    a = legacy("a@example.com", "A")
    b = legacy("b@example.com", "B")
    assert {:error, :not_found} = People.merge_persons(a, [b, -1])
    assert People.get_person(b.id).id == b.id

    assert {:error, :self_merge} =
             People.update_person_resource(a, %{full_name: "Changed"}, [], %{
               merge_with_person_id: a.id
             })

    assert People.get_person(a.id).full_name == "A"
  end

  test "bulk deletion accepts deduplicated current IDs from resolved people" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")
    assert {:ok, _} = People.merge_persons(survivor, loser)

    assert {:ok, %{deleted_count: 1, failed_ids: []}} =
             People.bulk_delete_people([People.get_person(loser.id).id, survivor.id])

    assert People.get_person(loser.id) == nil
    assert People.get_person(survivor.id) == nil
  end

  test "ordinary relationship updates use resolved IDs and preserve explicit channel activity" do
    survivor = legacy(nil, "Current")
    loser = legacy(nil, "Old")
    other = legacy(nil, "Other")
    assert {:ok, _} = People.merge_persons(survivor, loser)
    person = People.get_person(loser.id)

    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "slack", person_id: other.id})

    assert {:ok, updated} =
             Conversations.update_conversation(conversation, %{person_id: person.id})

    assert updated.person_id == survivor.id

    {:ok, channel} =
      People.add_channel(%{person_id: other.id, platform: "slack", channel_identifier: "move"})

    time = ~U[2026-01-01 00:00:00Z]

    assert {:ok, updated} =
             People.update_channel(channel, %{person_id: person.id, last_interaction_at: time})

    assert updated.person_id == survivor.id
    assert updated.last_interaction_at == time
  end

  test "final unique failure rolls back retired aliases, moved relationships and nested edits" do
    survivor = legacy(" TAKEN@example.com ", "Survivor")
    loser = legacy("loser@example.com", "Loser")
    legacy("taken@example.com", "Outside group")

    {:ok, channel} =
      People.add_channel(%{
        person_id: loser.id,
        platform: "slack",
        channel_identifier: "rollback"
      })

    capture_writes()

    assert {:error, changeset} =
             People.update_person_resource(survivor, %{phone: "new"}, [], %{
               merge_with_person_id: loser.id
             })

    assert errors_on(changeset).email == ["has already been taken"]
    assert_received {:merge_write, "UPDATE \"channels\"" <> _, _}
    assert_received {:merge_write, "DELETE FROM \"people\"" <> _, [loser_id]}
    assert loser_id == loser.id
    assert Repo.get!(Person, loser.id).merged_person_ids == []
    assert Repo.get!(Person, survivor.id).email == " TAKEN@example.com "
    assert Repo.get!(Person, survivor.id).phone == nil
    assert People.get_channel(channel.id).person_id == loser.id
  end

  test "People resolves old IDs before permissions and ownership consume current identity" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")
    resource = %Zaq.Engine.Workflows.Workflow{id: Ecto.UUID.generate()}
    {:ok, _} = Zaq.Permissions.grant(resource, %{person_id: loser.id, access_rights: ["run"]})
    assert {:ok, _} = People.merge_persons(survivor, loser)
    person = People.get_person(loser.id)
    assert person.id == survivor.id
    assert Zaq.Permissions.can?(person, :run, resource)
    refute Zaq.Permissions.can?(nil, :run, resource)

    {:ok, channel} =
      People.add_channel(%{person_id: person.id, platform: "slack", channel_identifier: "old-id"})

    assert channel.person_id == survivor.id
    assert {:ok, matched} = People.match_by_channel("slack", "old-id")
    assert matched.id == survivor.id
    assert {:ok, updated} = People.update_person(person, %{phone: "123"})
    assert updated.id == survivor.id
    refute Repo.get(Person, loser.id)
    assert People.get_person(nil) == nil
    assert People.get_person_with_channels(-1) == nil
  end

  test "grants targeting person resources are retained and unioned, including team principals" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")
    viewer = legacy(nil, "Viewer")
    {:ok, team} = People.create_team(%{name: "Viewers"})
    {:ok, _} = Zaq.Permissions.grant(survivor, %{person_id: viewer.id, access_rights: ["read"]})

    {:ok, _} =
      Zaq.Permissions.grant(loser, %{
        person_id: viewer.id,
        team_id: team.id,
        access_rights: ["write"]
      })

    assert {:ok, _} = People.merge_persons(survivor, loser)
    assert Zaq.Permissions.can?(viewer, :read, survivor)
    assert Zaq.Permissions.can?(viewer, :write, survivor)
    resolved = People.get_person(loser.id)
    assert Zaq.Permissions.can?(viewer, :write, resolved)
    refute Zaq.Permissions.can?(viewer, :write, loser)
    assert Permissions.list({"person", loser.id}) == []
    grants = Zaq.Permissions.list(survivor)
    assert Enum.any?(grants, &(&1.team_id == team.id and &1.access_rights == ["write"]))
    refute Enum.any?(grants, &(&1.person_id == viewer.id and not is_nil(&1.team_id)))

    assert {:ok, result} =
             QueryResources.run(
               %{mode: "query", resource_type: "person", id: resolved.id, fields: ["id"]},
               %{actor: %{person: %{id: viewer.id}}}
             )

    assert result.resource == %{id: survivor.id}

    assert {:error, :unauthorized} =
             QueryResources.run(
               %{mode: "query", resource_type: "person", id: resolved.id},
               %{}
             )

    assert {:ok, all} =
             QueryResources.run(
               %{mode: "query", resource_type: "person", fields: ["id"]},
               %{skip_permissions: true}
             )

    refute Enum.any?(all.resources, &(&1.id == loser.id))
  end

  test "actor constructed from a retrieved Person uses current teams and survivor grants" do
    old = legacy(nil, "Old actor")
    current = legacy(nil, "Current actor")
    target = legacy(nil, "Private target")
    {:ok, team} = People.create_team(%{name: "Stale snapshot team"})
    {:ok, _} = Zaq.Permissions.grant(target, %{team_id: team.id, access_rights: ["read"]})
    assert {:ok, _} = People.merge_persons(current, old)
    params = %{mode: "query", resource_type: "person", id: target.id, fields: ["id"]}
    person = People.get_person(old.id)
    actor = %{actor: %{person: IdentityResolver.person_payload(person)}}
    assert {:error, :unauthorized} = QueryResources.run(params, actor)
    {:ok, grant} = Zaq.Permissions.grant(target, %{person_id: person.id, access_rights: ["read"]})
    assert grant.person_id == current.id
    assert {:ok, result} = QueryResources.run(params, actor)
    assert result.resource == %{id: target.id}
  end

  test "history uses name, then priority channel, then ID fallback; ordinary attrs cannot forge aliases" do
    survivor = legacy(nil, "Kept")
    nameless = legacy(nil, " ")
    fallback = legacy(nil, "")

    {:ok, lower_priority} =
      People.add_channel(%{
        person_id: nameless.id,
        platform: "slack",
        channel_identifier: "lower-priority-label"
      })

    {:ok, _} =
      People.add_channel(%{
        person_id: nameless.id,
        platform: "slack",
        channel_identifier: "primary-label"
      })

    {:ok, _} = People.update_channel(lower_priority, %{weight: 9})
    assert {:ok, merged} = People.merge_persons(survivor, [nameless, fallback])

    assert Enum.map(merged.merge_history, & &1["label"]) == [
             "primary-label",
             "Person ##{fallback.id}"
           ]

    next = legacy(nil, "Next")
    history = merged.merge_history
    assert {:ok, merged_again} = People.merge_persons(next, survivor)

    assert Enum.filter(merged_again.merge_history, &(&1["id"] in [nameless.id, fallback.id])) ==
             history

    assert {:ok, updated} =
             People.update_person(merged_again, %{merged_person_ids: [999], merge_history: []})

    assert updated.merged_person_ids == merged_again.merged_person_ids
    assert updated.merge_history == merged_again.merge_history

    assert {:ok, created} =
             People.create_person(%{
               full_name: "Forged",
               merged_person_ids: [999],
               merge_history: [%{id: 999}]
             })

    assert created.merged_person_ids == []
    assert created.merge_history == []
  end

  test "ordinary routing update validates even unchanged legacy policy; merge rolls back all writes" do
    {:ok, survivor} = People.create_person(%{full_name: "Kept", email: "kept@example.com"})
    {:ok, loser} = People.create_person(%{full_name: "Other", email: "other@example.com"})
    rule = Repo.insert!(%IncomingMessageRoutingRule{person_id: loser.id, routing_mode: :agent})
    original_channels = People.get_person_with_channels!(loser.id).channels
    resource = {"document", "rollback-routing"}
    {:ok, grant} = Permissions.grant(resource, %{person_id: loser.id, access_rights: ["read"]})
    assert {:error, changeset} = IncomingMessageRouting.upsert_rule(rule, %{})
    assert errors_on(changeset).configured_agent_id == ["can't be blank"]
    assert {:error, merge_changeset} = People.merge_persons(survivor, loser)
    assert errors_on(merge_changeset).configured_agent_id == ["can't be blank"]
    assert Repo.get!(IncomingMessageRoutingRule, rule.id) == rule
    assert Permissions.list(resource) == [Repo.preload(grant, [:person, :team])]
    assert People.get_person_with_channels!(loser.id).channels == original_channels
    assert People.get_person(loser.id).id == loser.id
    assert People.get_person(survivor.id).merged_person_ids == []
    assert People.get_person_with_channels!(loser.id).channels != []
    assert {:ok, updated} = IncomingMessageRouting.upsert_rule(rule, %{routing_mode: :none})
    assert updated.routing_mode == :none
    assert {:ok, _} = People.merge_persons(survivor, loser)
  end

  test "merge preserves an unchanged winner and its grant without validation writes" do
    {:ok, survivor} = People.create_person(%{full_name: "Winner"})
    {:ok, loser} = People.create_person(%{full_name: "Loser"})
    {:ok, viewer} = People.create_person(%{full_name: "Viewer"})
    timestamp = ~U[2020-01-01 00:00:00Z]

    rule =
      Repo.insert!(%IncomingMessageRoutingRule{
        person_id: survivor.id,
        routing_mode: :none,
        updated_at: timestamp
      })

    {:ok, _} = IncomingMessageRouting.upsert_rule(%{person_id: loser.id}, %{routing_mode: :none})
    resource = {"incoming_message_routing_rule", to_string(rule.id)}
    {:ok, grant} = Permissions.grant(resource, %{person_id: viewer.id, access_rights: ["read"]})

    assert {:ok, _} = People.merge_persons(survivor, loser)
    assert IncomingMessageRouting.get_rule(%{person_id: survivor.id}) == rule
    assert Permissions.list(resource) == [Repo.preload(grant, [:person, :team])]
  end

  test "merge moves a loser winner in place preserving its grant reference" do
    {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    {:ok, loser} = People.create_person(%{full_name: "Loser"})
    {:ok, viewer} = People.create_person(%{full_name: "Viewer"})

    {:ok, rule} =
      IncomingMessageRouting.upsert_rule(%{person_id: loser.id}, %{routing_mode: :none})

    resource = {"incoming_message_routing_rule", to_string(rule.id)}
    {:ok, grant} = Permissions.grant(resource, %{person_id: viewer.id, access_rights: ["read"]})

    assert {:ok, _} = People.merge_persons(survivor, loser)
    updated = IncomingMessageRouting.get_rule(%{person_id: survivor.id})
    assert updated.id == rule.id
    assert updated.person_id == survivor.id
    assert Permissions.list(resource) == [Repo.preload(grant, [:person, :team])]
  end

  test "one historical Person retrieval feeds literal downstream reads without repeated actor loads" do
    {:ok, old} = People.create_person(%{full_name: "Old"})
    {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    {:ok, team} = People.create_team(%{name: "Current team"})
    {:ok, survivor} = People.assign_team(survivor, team.id)
    {:ok, document} = Document.create(%{source: "boundary.md", content: "Private"})
    {:ok, _} = Permissions.grant(document, %{person_id: old.id, access_rights: ["read"]})
    {:ok, _} = Permissions.grant(old, %{person_id: old.id, access_rights: ["read"]})

    {:ok, conversation} =
      Conversations.create_conversation(%{channel_type: "slack", person_id: old.id})

    {:ok, rule} = IncomingMessageRouting.upsert_rule(%{person_id: old.id}, %{routing_mode: :none})
    {:ok, _} = People.merge_persons(survivor, old)

    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:zaq, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and metadata[:source] == "people", do: send(owner, :person_query)
        end,
        nil
      )

    try do
      person = People.get_person(old.id)
      assert person.id == survivor.id
      assert_receive :person_query
      refute_received :person_query

      assert Permissions.can?(person, :read, document)
      assert Permissions.access(person, :read).person == person
      assert [grant] = Ingestion.list_person_permissions(person.id)
      assert grant.person_id == person.id
      assert [%{id: id}] = Conversations.list_conversations(person_id: person.id)
      assert id == conversation.id
      # Conversation results retain their existing Person association preload.
      assert_received :person_query
      refute_received :person_query
      assert Conversations.list_conversations(person_id: old.id) == []
      assert IncomingMessageRouting.get_rule(%{person_id: person.id}).id == rule.id
      assert IncomingMessageRouting.get_rule(%{person_id: old.id}) == nil

      incoming =
        Incoming.new(%{content: "hello", provider: :slack, channel_id: "channel", person: person})

      assert IncomingMessageRouting.resolve(incoming).rule.id == rule.id

      assert DocumentAccess.list_permitted_document_ids(person.id, person.team_ids, [document.id]) ==
               [document.id]

      assert [%{source: "boundary.md"}] =
               DocumentAccess.list_accessible_documents(
                 person_id: person.id,
                 team_ids: person.team_ids
               )

      context = %{actor: %{person: IdentityResolver.person_payload(person)}}
      refute_received :person_query

      assert {:ok, %{resource: %{id: result_id}}} =
               QueryResources.run(
                 %{mode: "query", resource_type: "person", id: person.id, fields: ["id"]},
                 context
               )

      assert result_id == person.id
      assert Permissions.list({"person", old.id}) == []
      refute_received :person_query
    after
      :telemetry.detach(handler)
    end
  end

  @tag :legacy_channels
  test "duplicate channels retain survivor values, fill nested metadata and keep latest interaction" do
    survivor =
      Repo.insert!(%Person{
        email: "CHANNEL@example.com",
        full_name: " ",
        metadata: %{"nested" => %{"keep" => false, "fill" => " "}}
      })

    loser =
      Repo.insert!(%Person{
        email: "channel@example.com",
        full_name: "Filled name",
        metadata: %{"nested" => %{"keep" => true, "fill" => "value"}}
      })

    first = channel(survivor.id, "shared", "Kept")
    second = channel(loser.id, "shared", "Discarded")
    sql("UPDATE channels SET last_interaction_at = '2026-01-01' WHERE id = $1", [first])

    sql("UPDATE channels SET last_interaction_at = '2026-02-01', phone = '456' WHERE id = $1", [
      second
    ])

    assert {:ok, merged} = People.merge_persons(survivor, loser)

    assert sql("SELECT display_name, phone, last_interaction_at FROM channels WHERE id = $1", [
             first
           ]).rows ==
             [["Kept", "456", ~N[2026-02-01 00:00:00]]]

    assert merged.full_name == "Filled name"
    assert merged.metadata == %{"nested" => %{"keep" => false, "fill" => "value"}}
  end

  @tag :legacy_channels
  test "multiway merge fills profile and preserves linked data with person-only notification correction" do
    survivor =
      Repo.insert!(%Person{
        email: " ÄLİCE@EXAMPLE.COM ",
        full_name: "Survivor",
        status: "inactive",
        team_ids: [11],
        metadata: %{"keep" => "yes"}
      })

    loser =
      Repo.insert!(%Person{
        email: "äli̇ce@example.com",
        full_name: "Loser",
        phone: "123",
        role: "Engineer",
        team_ids: [11, 22],
        metadata: %{"extra" => "yes"}
      })

    third = Repo.insert!(%Person{email: "ÄLİCE@EXAMPLE.COM", full_name: "Third", team_ids: [33]})
    channel = channel(survivor.id, "shared", nil)
    channel(loser.id, "shared", "Alice")
    unique_channel = channel(third.id, "unique", "Third")

    {:ok, conversation} =
      Conversations.create_conversation(%{person_id: loser.id, channel_type: "slack"})

    sql(
      """
      INSERT INTO notification_logs (sender, payload, recipient_ref_type, recipient_ref_id, status, inserted_at)
      VALUES ('test', '{}', 'person', $1, 'sent', now()), ('test', '{}', 'user', $1, 'sent', now())
      """,
      [loser.id]
    )

    assert {:ok, person} = People.merge_persons(survivor, [loser, third])
    assert person.email == "äli̇ce@example.com"
    assert person.full_name == "Survivor"
    assert person.phone == "123"
    assert person.role == "Engineer"
    assert person.status == "inactive"
    refute person.incomplete
    assert person.team_ids == [11, 22, 33]
    assert person.metadata == %{"keep" => "yes", "extra" => "yes"}
    assert People.get_person(loser.id).id == survivor.id
    assert People.get_person(third.id).id == survivor.id

    assert sql(
             "SELECT id, person_id, display_name FROM channels WHERE platform = 'slack' ORDER BY id"
           ).rows ==
             [[channel, survivor.id, "Alice"], [unique_channel, survivor.id, "Third"]]

    assert Repo.get!(conversation.__struct__, conversation.id).person_id == survivor.id

    assert sql("SELECT recipient_ref_type, recipient_ref_id FROM notification_logs ORDER BY id").rows ==
             [["person", survivor.id], ["user", loser.id]]

    assert Enum.map(person.merge_history, & &1["id"]) == [loser.id, third.id]
  end

  test "unions routing scopes and keeps survivor policy on every partial unique index" do
    survivor = legacy("ROUTING@example.com", "Survivor")
    loser = legacy("routing@example.com", "Loser")

    [[config]] =
      sql("""
      INSERT INTO channel_configs (name, provider, url, token, inserted_at, updated_at)
      VALUES ('Merge', 'merge-routing', '', '', now(), now()) RETURNING id
      """).rows

    [[channel]] =
      sql(
        """
        INSERT INTO retrieval_channels (channel_config_id, channel_id, channel_name, team_id, team_name, inserted_at, updated_at)
        VALUES ($1, 'merge', 'Merge', 'team', 'Team', now(), now()) RETURNING id
        """,
        [config]
      ).rows

    for scope <- [
          [nil, nil, nil],
          [config, nil, nil],
          [config, nil, "topic"],
          [config, channel, nil]
        ] do
      rule(loser.id, "agent", scope)
      rule(survivor.id, "none", scope)
    end

    unique = rule(loser.id, "none", [config, nil, "unique"])
    assert {:ok, _} = People.merge_persons(survivor, loser)

    assert sql(
             "SELECT count(*) FROM incoming_message_routing_rules WHERE person_id = $1 AND routing_mode = 'none'",
             [survivor.id]
           ).rows == [[5]]

    assert sql("SELECT person_id FROM incoming_message_routing_rules WHERE id = $1", [unique]).rows ==
             [[survivor.id]]
  end

  test "workflow definitions, execution snapshots, cached results, jobs and approval audit stay immutable" do
    survivor = legacy("USER@example.com", "Survivor").id
    loser = legacy("user@example.com", "Loser").id
    workflow_id = Ecto.UUID.bingenerate()

    nodes = [
      %{
        "id" => "notify",
        "params" => %{
          "person_id" => loser,
          "user_id" => loser,
          "person_ids" => [loser, survivor],
          "message" => "person_id=#{loser}"
        }
      }
    ]

    sql(
      """
      INSERT INTO workflows (id, name, status, nodes, edges, inserted_at, updated_at)
      VALUES ($1, 'Merge', 'draft', $2, '[]', now(), now())
      """,
      [workflow_id, nodes]
    )

    job = %{
      "schedule_id" => "merge",
      "action_key" => "people.notify_person",
      "params" => %{"person_id" => to_string(loser)}
    }

    sql(
      "INSERT INTO oban_jobs (worker, queue, args) VALUES ('Zaq.Engine.ActionSchedules.Worker', 'scheduled_actions', $1)",
      [job]
    )

    run_id = Ecto.UUID.bingenerate()
    actor = %{"person" => %{"id" => loser, "team_ids" => [7]}, "user_id" => loser}
    source_event = %{"actor" => actor, "request" => %{"person_id" => loser}}

    sql(
      """
      INSERT INTO workflow_runs (id, workflow_id, steps_snapshot, source_event, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, now(), now())
      """,
      [run_id, workflow_id, %{"nodes" => nodes}, source_event]
    )

    sql(
      """
      INSERT INTO step_approvals (id, workflow_run_id, step_name, approval_token, approved_by, status, inserted_at, updated_at)
      VALUES ($1, $2, 'approval', 'merge-approval', $3, 'approved', now(), now())
      """,
      [Ecto.UUID.bingenerate(), run_id, to_string(loser)]
    )

    results = %{
      "recipient_ref" => ["person", loser],
      "person_id" => nil,
      "items" => [
        %{"person_id" => "external"},
        %{"person_id" => "000000"},
        %{"person_id" => true}
      ],
      "merge_with_person_id" => loser
    }

    sql(
      """
      INSERT INTO workflow_action_results (id, workflow_run_id, step_name, step_index, input, results, inserted_at, updated_at)
      VALUES ($1, $2, 'notify', 0, $3, $4, now(), now())
      """,
      [Ecto.UUID.bingenerate(), run_id, %{"person_id" => loser}, results]
    )

    assert {:ok, _} = People.merge_persons(survivor, loser)

    [[[%{"params" => params}]]] =
      sql("SELECT nodes FROM workflows WHERE id = $1", [workflow_id]).rows

    assert params["person_id"] == loser
    assert params["person_ids"] == [loser, survivor]
    assert params["user_id"] == loser
    assert params["message"] == "person_id=#{loser}"
    [[args]] = sql("SELECT args FROM oban_jobs WHERE args->>'schedule_id' = 'merge'").rows
    assert args["params"]["person_id"] == to_string(loser)
    assert People.get_person(args["params"]["person_id"]).id == survivor

    [[event, snapshot]] =
      sql("SELECT source_event, steps_snapshot FROM workflow_runs WHERE id = $1", [run_id]).rows

    assert event["actor"]["person"] == %{"id" => loser, "team_ids" => [7]}
    assert event["actor"]["user_id"] == loser
    assert event["request"]["person_id"] == loser
    assert hd(snapshot["nodes"])["params"]["person_id"] == loser

    assert sql("SELECT approved_by FROM step_approvals WHERE workflow_run_id = $1", [run_id]).rows ==
             [[to_string(loser)]]

    [[input, updated_results]] =
      sql("SELECT input, results FROM workflow_action_results WHERE workflow_run_id = $1", [
        run_id
      ]).rows

    assert input == %{"person_id" => loser}
    assert updated_results == results
  end

  for edit_target <- [:retained, :discarded] do
    @tag :legacy_channels
    test "resource merge #{edit_target} channel ID is never retargeted" do
      survivor = legacy(nil, "Survivor")
      loser = legacy(nil, "Loser")
      kept = channel(survivor.id, "shared", "Kept")
      discarded = channel(loser.id, "shared", "Discarded")
      target = if unquote(edit_target) == :retained, do: kept, else: discarded

      result =
        People.update_person_resource(
          loser,
          %{full_name: "Explicit"},
          [%{id: target, display_name: "Edited"}],
          %{merge_with_person_id: survivor.id, merge_precedence: "other"}
        )

      if unquote(edit_target) == :retained do
        assert {:ok, merged} = result
        assert merged.id == survivor.id
        assert merged.full_name == "Explicit"
        assert People.get_channel(kept).display_name == "Edited"
        assert People.get_channel(discarded) == nil
      else
        assert {:error, :channel_not_found} = result
        assert People.get_person!(survivor.id) == survivor
        assert People.get_person!(loser.id) == loser
        assert People.get_channel(kept).display_name == "Kept"
        assert People.get_channel(discarded).display_name == "Discarded"
      end
    end
  end

  test "successful nested merge remains subject to caller rollback" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")

    assert {:error, :caller_failure} =
             Repo.transaction(fn ->
               assert {:ok, merged} = People.merge_persons(survivor, loser)
               assert merged.merged_person_ids == [loser.id]
               Repo.rollback(:caller_failure)
             end)

    assert People.get_person!(survivor.id) == survivor
    assert People.get_person!(loser.id) == loser
  end

  test "invalid final channel prevents relationship and person writes" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")

    Repo.insert!(%PersonChannel{
      person_id: loser.id,
      platform: "telegram",
      channel_identifier: "bad-weight",
      weight: -1
    })

    capture_writes()
    assert {:error, error} = People.merge_persons(survivor, loser)
    assert errors_on(error).weight == ["must be greater than or equal to 0"]
    refute_received {:merge_write, _, _}
  end

  test "invalid conversation prevents channel transfers and loser deletion" do
    survivor = legacy(nil, "Survivor")
    loser = legacy(nil, "Loser")
    channel(loser.id, "would-move", "Original")

    Repo.insert!(%Zaq.Engine.Conversations.Conversation{
      person_id: loser.id,
      channel_type: "slack",
      status: "invalid"
    })

    capture_writes()
    assert {:error, error} = People.merge_persons(survivor, loser)
    assert errors_on(error).status == ["is invalid"]
    refute_received {:merge_write, _, _}
  end

  test "invalid final profile prevents every satellite write" do
    survivor = Repo.insert!(%Person{full_name: "Survivor", status: "invalid"})
    loser = legacy(nil, "Loser")
    channel(loser.id, "would-move", "Original")
    capture_writes()
    assert {:error, error} = People.merge_persons(survivor, loser)
    assert errors_on(error).status == ["is invalid"]
    refute_received {:merge_write, _, _}
  end

  defp capture_writes do
    handler = {__MODULE__, make_ref()}
    owner = self()

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner and Regex.match?(~r/^(INSERT|UPDATE|DELETE) /, metadata.query),
          do: send(owner, {:merge_write, metadata.query, metadata.params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp channel(person_id, identifier, name) do
    {:ok, channel} =
      People.add_channel(%{
        person_id: person_id,
        platform: "slack",
        channel_identifier: identifier,
        display_name: name
      })

    channel.id
  end

  defp rule(person_id, mode, [config, channel, topic]) do
    agent_id =
      if mode == "agent" do
        Repo.insert!(%Zaq.Agent.ConfiguredAgent{
          name: "Routing #{System.unique_integer([:positive])}",
          job: "Route",
          model: "test",
          conversation_enabled: true,
          credential_id: ai_credential_fixture().id
        }).id
      end

    Repo.insert!(%IncomingMessageRoutingRule{
      person_id: person_id,
      routing_mode: String.to_existing_atom(mode),
      channel_config_id: config,
      retrieval_channel_id: channel,
      topic_id: topic,
      configured_agent_id: agent_id
    }).id
  end

  defp sql(statement, params \\ []), do: Repo.query!(statement, params, log: false)

  defp legacy(email, name) do
    %Person{email: email, full_name: name} |> Repo.insert!()
  end
end
