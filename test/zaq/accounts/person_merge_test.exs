defmodule Zaq.Accounts.PersonMergeTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Agent.Tools.Resources.QueryResources
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.ChannelHistoryAdmin
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, Transcript, TranscriptMessage}
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.PeopleGateway
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, DocumentAccess}
  alias Zaq.People.IdentityResolver
  alias Zaq.Permissions
  alias Zaq.Permissions.{ChannelHistoryResource, PermissionRevokerMock, ResourcePermission}

  import Mox
  import Zaq.SystemConfigFixtures, only: [ai_credential_fixture: 0]
  setup :verify_on_exit!

  test "merging Persons keeps equal opaque IDs from distinct connectors separate" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")

    config_ids =
      for name <- ["Workspace A", "Workspace B"] do
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: name,
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()
        |> Map.fetch!(:id)
      end

    for {person_id, config_id} <- Enum.zip([survivor.id, loser.id], config_ids) do
      {:ok, _} =
        People.add_channel(%{
          person_id: person_id,
          platform: "slack",
          channel_identifier: "same-id",
          channel_config_id: config_id
        })
    end

    assert {:ok, merged} = People.merge_persons(survivor, loser)
    assert Enum.sort(Enum.map(merged.channels, & &1.channel_config_id)) == Enum.sort(config_ids)
  end

  property "multi-loser resource and principal collisions union rights without team leakage" do
    check all(reversed <- boolean(), max_runs: 6) do
      survivor = person(nil, "Survivor")
      first = person(nil, "First")
      second = person(nil, "Second")
      outsider = person(nil, "Unaffected")
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
    survivor = person(nil, "Survivor")
    first = person(nil, "First")
    second = person(nil, "Second")
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

  test "merging people retains separate manual and provider channel grants" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
    resource = ChannelHistoryResource.for("mattermost", 12, "room-A")

    {:ok, _} = Permissions.grant(resource, %{person_id: survivor.id, access_rights: ["read"]})

    {:ok, _} =
      Permissions.grant(resource, %{
        person_id: loser.id,
        source_key: "provider:mattermost:12:user-9",
        access_rights: ["view"]
      })

    assert {:ok, _} = People.merge_persons(survivor, loser)

    assert Enum.sort(Enum.map(Permissions.list(resource), &{&1.source_key, &1.access_rights})) ==
             [{"manual", ["read"]}, {"provider:mattermost:12:user-9", ["view"]}]
  end

  test "grant validation failure prevents all writes to originals and merged channels" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")

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
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
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
      survivor = person(nil, "Explicit")
      {:ok, first} = People.create_person(%{full_name: "First", team_ids: teams})
      last = person(nil, "Last")
      losers = if reversed, do: [last, first, first], else: [first, last, first]
      assert {:ok, merged} = People.merge_persons(survivor, losers)
      assert merged.full_name == "Explicit"
      assert MapSet.new(merged.team_ids) == MapSet.new(teams)
      assert Enum.map(merged.merge_history, & &1["id"]) == [first.id, last.id]
    end
  end

  test "admin gateway exposes merge history and old IDs return canonical identity" do
    a = person("old@example.com", "Previous Name")
    b = person("kept@example.com", "Selected Survivor")

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

  test "group merge retains distinct identities and history and resolves flat chains" do
    a = person("first@example.com", "First")
    b = person("second@example.com", "Second")
    c = person("third@example.com", "Third")

    capture_writes()
    assert {:ok, survivor} = People.merge_persons(b, [c, a])
    assert_received {:merge_write, "UPDATE \"people\"" <> query, params}
    assert query =~ "merged_person_ids"
    assert query =~ "merge_history"
    assert List.last(params) == b.id
    refute_received {:merge_write, "UPDATE \"people\"" <> _, _}
    assert survivor.id == b.id
    assert survivor.email == "second@example.com"

    assert Enum.sort(Enum.map(survivor.channels, & &1.channel_identifier)) ==
             ["first@example.com", "second@example.com", "third@example.com"]

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

    d = person("new@example.com", "Last")
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
    a = person(nil, "A")
    b = person(nil, "B")
    c = person(nil, "C")
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
    a = person("a@example.com", "A")
    b = person("b@example.com", "B")
    assert {:error, :not_found} = People.merge_persons(a, [b, -1])
    assert People.get_person(b.id).id == b.id

    assert {:error, :self_merge} =
             People.update_person_resource(a, %{full_name: "Changed"}, [], %{
               merge_with_person_id: a.id
             })

    assert People.get_person(a.id).full_name == "A"
  end

  test "bulk deletion accepts deduplicated current IDs from resolved people" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
    assert {:ok, _} = People.merge_persons(survivor, loser)

    assert {:ok, %{deleted_count: 1, failed_ids: []}} =
             People.bulk_delete_people([People.get_person(loser.id).id, survivor.id])

    assert People.get_person(loser.id) == nil
    assert People.get_person(survivor.id) == nil
  end

  test "ordinary channel updates preserve ownership and explicit activity after a merge" do
    survivor = person(nil, "Current")
    loser = person(nil, "Old")
    other = person(nil, "Other")
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

    assert updated.person_id == other.id
    assert updated.last_interaction_at == time
  end

  test "People resolves old IDs before permissions and ownership consume current identity" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
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
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
    viewer = person(nil, "Viewer")
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
    old = person(nil, "Old actor")
    current = person(nil, "Current actor")
    target = person(nil, "Private target")
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

  test "ordinary attrs cannot forge aliases or rewrite inherited merge history" do
    survivor = person(nil, "Kept")
    first = person(nil, "First")
    second = person(nil, "Second")
    assert {:ok, merged} = People.merge_persons(survivor, [first, second])
    assert Enum.map(merged.merge_history, & &1["label"]) == ["First", "Second"]
    next = person(nil, "Next")
    history = merged.merge_history
    assert {:ok, merged_again} = People.merge_persons(next, survivor)

    assert Enum.filter(merged_again.merge_history, &(&1["id"] in [first.id, second.id])) ==
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

  test "multiway merge fills profile and preserves linked data with person-only notification correction" do
    {:ok, survivor} =
      People.create_person(%{
        email: "survivor@example.com",
        full_name: "Survivor",
        status: "inactive",
        team_ids: [11],
        metadata: %{"keep" => "yes", "nested" => %{"keep" => false, "fill" => " "}}
      })

    {:ok, loser} =
      People.create_person(%{
        email: "loser@example.com",
        full_name: "Loser",
        phone: "123",
        role: "Engineer",
        team_ids: [11, 22],
        metadata: %{"extra" => "yes", "nested" => %{"keep" => true, "fill" => "value"}}
      })

    {:ok, third} =
      People.create_person(%{email: "third@example.com", full_name: "Third", team_ids: [33]})

    channel = channel(survivor.id, "survivor", "Survivor")
    loser_channel = channel(loser.id, "loser", "Alice")
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
    assert person.email == "survivor@example.com"
    assert person.full_name == "Survivor"
    assert person.phone == "123"
    assert person.role == "Engineer"
    assert person.status == "inactive"
    refute person.incomplete
    assert person.team_ids == [11, 22, 33]

    assert person.metadata == %{
             "keep" => "yes",
             "extra" => "yes",
             "nested" => %{"keep" => false, "fill" => "value"}
           }

    assert People.get_person(loser.id).id == survivor.id
    assert People.get_person(third.id).id == survivor.id

    assert sql(
             "SELECT id, person_id, display_name FROM channels WHERE platform = 'slack' ORDER BY id"
           ).rows ==
             [
               [channel, survivor.id, "Survivor"],
               [loser_channel, survivor.id, "Alice"],
               [unique_channel, survivor.id, "Third"]
             ]

    assert Repo.get!(conversation.__struct__, conversation.id).person_id == survivor.id

    assert sql("SELECT recipient_ref_type, recipient_ref_id FROM notification_logs ORDER BY id").rows ==
             [["person", survivor.id], ["user", loser.id]]

    assert Enum.map(person.merge_history, & &1["id"]) == [loser.id, third.id]
  end

  test "unions routing scopes and keeps survivor policy on every partial unique index" do
    survivor = person("survivor@example.com", "Survivor")
    loser = person("loser@example.com", "Loser")

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
    survivor = person("survivor@example.com", "Survivor").id
    loser = person("loser@example.com", "Loser").id
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

  test "successful nested merge remains subject to caller rollback" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")

    assert {:error, :caller_failure} =
             Repo.transaction(fn ->
               assert {:ok, merged} = People.merge_persons(survivor, loser)
               assert merged.merged_person_ids == [loser.id]
               Repo.rollback(:caller_failure)
             end)

    assert People.get_person!(survivor.id) == survivor
    assert People.get_person!(loser.id) == loser
  end

  test "merge transfers a replicated transcript and private execution to the survivor" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
    config = history_config()
    captured = replicated_capture(config, loser, "owned-before-merge")
    transcript = Repo.get!(Transcript, captured.transcript_id)
    message = Repo.get!(Message, captured.message_id)

    execution =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: loser.id,
        user_message_id: message.id,
        status: "pending",
        finalization_token_hash: capability("owned-before-merge")
      })
      |> Repo.insert!()

    assert {:ok, merged} = People.merge_persons(survivor, loser)
    transferred = Repo.get!(Transcript, transcript.id)
    assert transferred.owner_person_id == merged.id
    assert transferred.scope_key == transcript.scope_key
    assert transferred.permission_resource_id == transcript.permission_resource_id
    assert Repo.get!(ExecutionRecord, execution.id).person_id == merged.id
    assert Repo.get!(TranscriptMessage, captured.position_id).message_id == message.id
    assert {:ok, [_]} = Conversations.list_canonical_messages(merged, transcript.id)

    assert {:ok, detail} = ChannelHistoryAdmin.dispatch(%{op: :detail, id: transcript.id})
    assert detail.transcript.owner_person_id == merged.id
    assert detail.transcript.owner.person_id == merged.id

    next = replicated_capture(config, merged, "owned-after-merge")
    assert next.transcript_id == transcript.id
  end

  test "merge retains overlapping replicas as separate permission resources" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
    outsider = person(nil, "Outsider")
    config = history_config()
    shared_copy = replicated_capture(config, survivor, "shared-before-merge", [loser.id])
    survivor_copy = replicated_capture(config, survivor, "survivor-only")
    loser_copy = replicated_capture(config, loser, "loser-only")
    loser_transcript = Repo.get!(Transcript, loser_copy.transcript_id)

    assert {:ok, _} =
             Permissions.grant(
               {loser_transcript.permission_resource_type,
                loser_transcript.permission_resource_id},
               %{person_id: outsider.id, access_rights: ["read"]}
             )

    assert {:ok, merged} = People.merge_persons(survivor, loser)
    assert Repo.get!(Transcript, survivor_copy.transcript_id).owner_person_id == merged.id
    assert Repo.get!(Transcript, loser_copy.transcript_id).owner_person_id == merged.id

    assert Repo.aggregate(
             from(p in TranscriptMessage, where: p.message_id == ^shared_copy.message_id),
             :count,
             :id
           ) == 2

    assert {:ok, loser_history} =
             Conversations.list_canonical_messages(outsider, loser_copy.transcript_id)

    assert Enum.map(loser_history, & &1.message_id) == [
             shared_copy.message_id,
             loser_copy.message_id
           ]

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(outsider, survivor_copy.transcript_id)

    next = replicated_capture(config, merged, "survivor-after-overlap")
    assert next.transcript_id == survivor_copy.transcript_id

    replay = replicated_capture(config, merged, "loser-only")
    assert replay.message_id == loser_copy.message_id
    assert Repo.aggregate(TranscriptMessage, :count, :id) == 5
  end

  test "caller rollback restores transcript and execution ownership" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
    config = history_config()
    captured = replicated_capture(config, loser, "rollback-owner")
    message = Repo.get!(Message, captured.message_id)

    execution =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: loser.id,
        user_message_id: message.id,
        status: "pending",
        finalization_token_hash: capability("rollback-owner")
      })
      |> Repo.insert!()

    assert {:error, :caller_failure} =
             Repo.transaction(fn ->
               assert {:ok, _} = People.merge_persons(survivor, loser)
               Repo.rollback(:caller_failure)
             end)

    assert Repo.get!(Transcript, captured.transcript_id).owner_person_id == loser.id
    assert Repo.get!(ExecutionRecord, execution.id).person_id == loser.id
    assert People.get_person!(loser.id).id == loser.id
  end

  test "invalid final channel prevents relationship and person writes" do
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")

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
    survivor = person(nil, "Survivor")
    loser = person(nil, "Loser")
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
    loser = person(nil, "Loser")
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

  defp history_config do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Merge history #{System.unique_integer([:positive])}",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://example.invalid",
      token: "fixture-token"
    })
    |> Repo.insert!()
  end

  defp replicated_capture(config, person, external_id, recipient_ids \\ []) do
    {:ok, facts} =
      Facts.for_capture(%{
        provider: config.provider,
        channel_config_id: config.id,
        channel_id: "merge-room",
        conversation_id: "merge-conversation",
        kind: :replicated,
        actor_person_id: person.id,
        recipient_person_ids: recipient_ids,
        thread_id: nil
      })

    {:ok, captured} =
      Conversations.capture_canonical_message(
        facts,
        %{
          role: "external",
          content: "message #{external_id}",
          external_message_id: external_id,
          author_id: "external-author",
          author_name: person.full_name
        },
        %{
          provider: config.provider,
          channel_config_id: config.id,
          provenance: "channel_adapter",
          source_scope: "merge-mailbox"
        }
      )

    position =
      Repo.get_by!(TranscriptMessage,
        transcript_id: captured.transcript_id,
        message_id: captured.message_id
      )

    Map.put(captured, :position_id, position.id)
  end

  defp capability(seed), do: seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()

  defp person(email, name) do
    {:ok, person} = People.create_person(%{email: email, full_name: name})
    person
  end
end
