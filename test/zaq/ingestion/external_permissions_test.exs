defmodule Zaq.Ingestion.ExternalPermissionsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person, PersonChannel, Team}
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.ExternalPermissions
  alias Zaq.Permissions
  alias Zaq.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  defp create_document do
    unique = System.unique_integer([:positive])
    {:ok, doc} = Document.upsert(%{source: "external-permissions/#{unique}.md"})
    doc
  end

  defp permissions_for(doc) do
    Ingestion.list_document_permissions(doc.id)
  end

  defp canonical_source(permissions) do
    id = "permission-source-#{System.unique_integer([:positive])}"

    record = %Record{
      id: id,
      kind: :file,
      permissions: permissions,
      attributes: %{"provider" => "google_drive", "config_id" => "12"}
    }

    {:ok, record} = Provenance.seal(record, %{"provider" => "google_drive", "config_id" => "12"})
    {:ok, document} = Document.insert_new(%{source: "data_source/google_drive/12/#{id}"})
    {record, document}
  end

  defp person_permission(person, rights) do
    %Record{
      id: "permission-#{System.unique_integer([:positive])}",
      kind: :permission,
      attributes: %{
        "type" => "person",
        "target_id" => to_string(person.id),
        "access_rights" => rights
      }
    }
  end

  defp source_snapshot(record, permissions) do
    {:ok, updated} =
      Provenance.seal(
        %{record | permissions: permissions},
        %{"provider" => "google_drive", "config_id" => "12"}
      )

    updated
  end

  test "canonical snapshots preserve manual and other-source grants through refresh and revocation" do
    {:ok, person} = People.create_person(%{full_name: "Source editor"})
    {record, doc} = canonical_source([person_permission(person, ["read", "edit"])])
    {:ok, manual} = Permissions.grant(doc, %{person_id: person.id, access_rights: ["delete"]})

    {:ok, other} =
      Permissions.grant(doc, %{
        person_id: person.id,
        source_key: "unrelated-provider",
        access_rights: ["read"]
      })

    assert :ok = ExternalPermissions.apply(record, [doc])
    source = Enum.find(permissions_for(doc), &String.starts_with?(&1.source_key, "source:"))
    assert source.source_key == "source:#{doc.source}"
    assert Enum.sort(source.access_rights) == ["read", "update"]

    assert :ok = ExternalPermissions.apply(record, [doc])
    assert Enum.any?(permissions_for(doc), &(&1.id == source.id))

    assert :ok = ExternalPermissions.apply(source_snapshot(record, nil), [doc])
    assert Enum.any?(permissions_for(doc), &(&1.id == source.id))
    assert :ok = ExternalPermissions.apply(source_snapshot(record, []), [doc])
    assert Enum.sort(Enum.map(permissions_for(doc), & &1.id)) == Enum.sort([manual.id, other.id])
  end

  test "canonical mapping unions principal rights and never widens write or move into update" do
    {:ok, person} = People.create_person(%{full_name: "Source writer"})

    {record, doc} =
      canonical_source([
        person_permission(person, ["read"]),
        person_permission(person, ["write", "move"])
      ])

    assert :ok = ExternalPermissions.apply(record, [doc])
    [grant] = permissions_for(doc)
    assert Enum.sort(grant.access_rights) == ["read", "write"]
    refute Permissions.can?(person, :update, doc)

    assert :ok =
             ExternalPermissions.apply(
               source_snapshot(record, [person_permission(person, ["edit"])]),
               [doc]
             )

    assert Permissions.can?(person, :update, doc)

    assert :ok =
             ExternalPermissions.apply(
               source_snapshot(record, [person_permission(person, ["manage"])]),
               [doc]
             )

    assert [grant] = permissions_for(doc)
    assert grant.access_rights == ["manage"]
    assert Permissions.can?(person, :manage, doc)
    refute Permissions.can?(person, :update, doc)
  end

  test "canonical projection rejects mismatched and unverified source identity without touching grants" do
    {:ok, person} = People.create_person(%{full_name: "Source reader"})
    {record, doc} = canonical_source([person_permission(person, ["read"])])
    assert :ok = ExternalPermissions.apply(record, [doc])
    before = permissions_for(doc)
    other = create_document()

    assert {:error, :source_mismatch} = ExternalPermissions.apply(record, [other])

    assert {:error, :invalid_source_record} =
             ExternalPermissions.apply(%{record | provenance_ref: nil}, [doc])

    assert {:error, :invalid_source_record} =
             ExternalPermissions.apply(%Record{id: "legacy", kind: :file, permissions: []}, [doc])

    assert permissions_for(doc) == before
  end

  test "canonical projection rolls back all grants when a principal cannot be persisted" do
    {:ok, person} = People.create_person(%{full_name: "Source transaction"})
    {record, doc} = canonical_source([person_permission(person, ["read"])])
    assert :ok = ExternalPermissions.apply(record, [doc])
    before = permissions_for(doc)
    missing = %{id: 2_000_000_000}

    invalid =
      source_snapshot(record, [
        person_permission(person, ["edit"]),
        person_permission(missing, ["read"])
      ])

    assert {:error, _} = ExternalPermissions.apply(invalid, [doc])
    assert permissions_for(doc) == before
  end

  test "canonical projection ignores unsigned owner and permission raw authority" do
    {:ok, person} = People.create_person(%{full_name: "Authenticated reader"})
    {:ok, attacker} = People.create_person(%{full_name: "Unsigned owner"})
    {record, doc} = canonical_source([person_permission(person, ["read"])])
    [permission] = record.permissions

    tampered = %{
      record
      | owners: [%{"type" => "person", "target_id" => to_string(attacker.id)}],
        permissions: [
          %{
            permission
            | raw: %{
                "type" => "team",
                "target_id" => to_string(Permissions.everyone_team_id()),
                "access_rights" => ["update"]
              }
          }
        ]
    }

    assert {:ok, _} = Provenance.verify(tampered)
    assert :ok = ExternalPermissions.apply(tampered, [doc])
    [grant] = permissions_for(doc)
    assert grant.person_id == person.id
    assert grant.access_rights == ["read"]
    refute Permissions.can?(attacker, :read, doc)
    refute Permissions.can?(person, :update, doc)
  end

  test "canonical provider email principals reuse existing People identity" do
    {:ok, person} =
      People.create_person(%{
        full_name: "Existing source person",
        email: "canonical-#{System.unique_integer([:positive])}@example.com"
      })

    permission = %Record{
      id: "provider-user",
      kind: :permission,
      attributes: %{
        "principal_type" => "user",
        "principal_key" => person.email,
        "access_rights" => ["read", "edit"]
      }
    }

    {record, document} = canonical_source([permission])

    assert :ok = ExternalPermissions.apply(record, [document])
    [grant] = permissions_for(document)
    assert grant.person_id == person.id
    assert Enum.sort(grant.access_rights) == ["read", "update"]
  end

  test "canonical empty rights do not acquire authority from roles or unsigned attributes" do
    {:ok, person} = People.create_person(%{full_name: "Explicit zero rights"})
    permission = person_permission(person, [])
    permission = %{permission | attributes: Map.put(permission.attributes, "role", "writer")}
    {record, document} = canonical_source([permission])

    assert :ok = ExternalPermissions.apply(record, [document])
    assert permissions_for(document) == []

    [permission] = record.permissions

    tampered = %{
      record
      | permissions: [
          %{permission | attributes: Map.delete(permission.attributes, "access_rights")}
        ]
    }

    assert {:ok, _} = Provenance.verify(tampered)
    assert :ok = ExternalPermissions.apply(tampered, [document])
    assert permissions_for(document) == []
  end

  test "canonical group principals cannot become an individual Person grant by email coincidence" do
    {:ok, person} =
      People.create_person(%{
        full_name: "Group-shaped identity",
        email: "group-#{System.unique_integer([:positive])}@example.com"
      })

    permission = %Record{
      id: "group-permission",
      kind: :permission,
      attributes: %{
        "principal_type" => "group",
        "principal_key" => person.email,
        "access_rights" => ["read"]
      }
    }

    {record, document} = canonical_source([permission])

    assert {:error, {:permission_projection_failed, :unsupported_target_type}} =
             ExternalPermissions.apply(record, [document])

    assert permissions_for(document) == []
    refute Permissions.can?(person, :read, document)
  end

  property "canonical duplicate rights are order-independent and refreshes are idempotent" do
    {:ok, person} = People.create_person(%{full_name: "Source rights invariant"})
    {record, document} = canonical_source([])

    check all(
            rights <-
              list_of(member_of(["read", "write", "edit", "move", "create", "delete"]),
                min_length: 1,
                max_length: 8
              ),
            max_runs: 12
          ) do
      permissions = Enum.map(rights, &person_permission(person, [&1]))
      assert :ok = ExternalPermissions.apply(source_snapshot(record, permissions), [document])
      first = Enum.map(permissions_for(document), &{&1.id, Enum.sort(&1.access_rights)})

      assert :ok =
               ExternalPermissions.apply(source_snapshot(record, Enum.reverse(permissions)), [
                 document
               ])

      assert Enum.map(permissions_for(document), &{&1.id, Enum.sort(&1.access_rights)}) == first
      refute Permissions.can?(person, :update, document) and "edit" not in rights
    end
  end

  test "imports plain map permission by canonical Person reference with default read rights" do
    doc = create_document()
    {:ok, person} = People.create_person(%{full_name: "Provider User"})

    record = %Record{
      id: "file-1",
      kind: :file,
      attributes: %{provider: "slack"},
      permissions: [
        %{type: "person", target_id: to_string(person.id), role: "custom_role"}
      ]
    }

    assert :ok = ExternalPermissions.apply(record, [doc])

    [permission] = permissions_for(doc)
    assert permission.person_id == person.id
    assert permission.access_rights == ["read"]
    assert permission.person.full_name == "Provider User"
  end

  test "opaque provider identifiers without connector scope do not invent links or grants" do
    doc = create_document()

    record = %Record{
      id: "unscoped",
      kind: :file,
      attributes: %{provider: "slack"},
      permissions: [%{id: "provider-user-1", display_name: "Unscoped provider user"}]
    }

    assert :ok = ExternalPermissions.apply(record, [doc])
    assert permissions_for(doc) == []
    refute Repo.exists?(from p in Person, where: p.full_name == "Unscoped provider user")
    refute Repo.exists?(from c in PersonChannel, where: c.channel_identifier == "provider-user-1")
  end

  test "ignores non-map permission principals that cannot be mapped" do
    doc = create_document()

    record = %Record{
      id: "file-2",
      kind: :file,
      attributes: %{"provider" => "google_drive"},
      permissions: ["not-a-principal"]
    }

    log =
      capture_log(fn ->
        assert :ok = ExternalPermissions.apply(record, [doc])
      end)

    assert log =~ "Skipped external permission principal"
    assert log =~ ~s(record "file-2")
    assert log =~ ":unmappable_principal"
    assert permissions_for(doc) == []
  end

  test "ignores principals with blank id and no email" do
    doc = create_document()

    record = %Record{
      id: "file-3",
      kind: :file,
      attributes: %{"provider" => "google_drive"},
      permissions: [%{"id" => "", "display_name" => "Blank Id", "role" => "reader"}]
    }

    log =
      capture_log(fn ->
        assert :ok = ExternalPermissions.apply(record, [doc])
      end)

    assert log =~ "Skipped external permission principal"
    assert log =~ ~s(record "file-3")
    assert log =~ ":unmappable_principal"
    assert log =~ ~s(role="reader")
    assert permissions_for(doc) == []
  end

  test "unsupported data_source fallback leaves no orphan Person or permission" do
    doc = create_document()

    record = %Record{
      id: "file-4",
      kind: :file,
      attributes: nil,
      permissions: [%{"id" => "fallback-user", "display_name" => "Fallback User"}]
    }

    log = capture_log(fn -> assert :ok = ExternalPermissions.apply(record, [doc]) end)
    assert log =~ "from data_source"
    assert log =~ "Skipped external permission principal"
    assert permissions_for(doc) == []
    refute Repo.exists?(from p in Person, where: p.full_name == "Fallback User")
    refute Repo.exists?(from c in PersonChannel, where: c.channel_identifier == "fallback-user")
  end

  test "unsupported provider ID without email is rejected atomically" do
    doc = create_document()

    record = %Record{
      id: "unsupported",
      kind: :file,
      attributes: %{provider: "google_drive"},
      permissions: [%{id: "unsupported-id", display_name: "Unsupported"}]
    }

    log = capture_log(fn -> assert :ok = ExternalPermissions.apply(record, [doc]) end)
    assert log =~ "from google_drive"
    assert permissions_for(doc) == []
    refute Repo.exists?(from p in Person, where: p.full_name == "Unsupported")
  end

  test "imports Record permission using raw email_address fallback" do
    doc = create_document()

    record = %Record{
      id: "file-5",
      kind: :file,
      permissions: [
        %Record{
          id: "perm-1",
          kind: :permission,
          name: "Raw Email User",
          raw: %{"email_address" => "raw-email@example.com", "role" => "commenter"}
        }
      ]
    }

    assert :ok = ExternalPermissions.apply(record, [doc])

    [permission] = permissions_for(doc)
    assert permission.access_rights == ["read"]
    assert permission.person.email == "raw-email@example.com"
  end

  test "imports direct person and team permission snapshots" do
    doc = create_document()

    {:ok, team} =
      %Team{}
      |> Team.changeset(%{name: "Storage Team #{System.unique_integer([:positive])}"})
      |> Repo.insert()

    record = %Record{
      id: "storage-entry-1",
      kind: :file,
      attributes: %{"provider" => "disk", "config_id" => "archives"},
      permissions: [
        %Record{
          id: "team-perm",
          kind: :permission,
          raw: %{
            "type" => "team",
            "target_id" => to_string(team.id),
            "access_rights" => ["read", "write"]
          }
        }
      ]
    }

    assert :ok = ExternalPermissions.apply(record, [doc])

    [permission] = permissions_for(doc)
    assert permission.team_id == team.id
    assert permission.access_rights == ["read", "write"]
  end

  test "skips a direct team target with explicit empty rights" do
    doc = create_document()
    record_id = "no-rights-entry-#{System.unique_integer([:positive])}"

    {:ok, team} =
      %Team{}
      |> Team.changeset(%{name: "No Rights Team #{System.unique_integer([:positive])}"})
      |> Repo.insert()

    record = %Record{
      id: record_id,
      kind: :file,
      permissions: [
        %Record{
          id: "no-rights-team-perm",
          kind: :permission,
          raw: %{
            "type" => "team",
            "target_id" => to_string(team.id),
            "access_rights" => [],
            "role" => "reader"
          }
        }
      ]
    }

    log =
      capture_log(fn ->
        assert :ok = ExternalPermissions.apply(record, [doc])
      end)

    assert log =~ "Skipped external permission principal"
    assert log =~ "record #{inspect(record_id)}"
    assert log =~ ":no_rights"
    assert log =~ ~s(role="reader")
    assert permissions_for(doc) == []
  end

  test "imports public permissions as Everyone grants without trusting the supplied target" do
    doc = create_document()
    {:ok, person} = People.create_person(%{full_name: "Public Reader"})
    everyone_id = Permissions.everyone_team_id()

    refute Permissions.can?(person, :read, doc)

    for target_id <- [nil, "", "not-the-everyone-team"] do
      record = %Record{
        id: "public-storage-entry",
        kind: :file,
        permissions: [
          %Record{
            id: "public-permission",
            kind: :permission,
            attributes: %{
              "type" => "public",
              "target_id" => target_id,
              "access_rights" => ["read"]
            }
          }
        ]
      }

      assert :ok = ExternalPermissions.apply(record, [doc])
      [permission] = permissions_for(doc)
      assert permission.team_id == everyone_id
      assert permission.person_id == nil
      assert permission.access_rights == ["read"]
      assert Permissions.can?(person, :read, doc)
      refute Permissions.can?(person, :write, doc)
    end

    assert :ok =
             ExternalPermissions.apply(
               %Record{id: "public-storage-entry", kind: :file, permissions: []},
               [doc]
             )

    assert permissions_for(doc) == []
    refute Permissions.can?(person, :read, doc)
  end

  test "does not grant public access for explicit empty rights" do
    doc = create_document()

    record = %Record{
      id: "public-no-rights",
      kind: :file,
      permissions: [%{"type" => "public", "access_rights" => []}]
    }

    log = capture_log(fn -> assert :ok = ExternalPermissions.apply(record, [doc]) end)

    assert log =~ ":no_rights"
    assert permissions_for(doc) == []
  end

  property "skips unsupported direct target types" do
    check all(
            type <- string(:alphanumeric, min_length: 1),
            type not in ["person", "team", "public"]
          ) do
      doc = create_document()
      record_id = "unsupported-target-#{System.unique_integer([:positive])}"

      record = %Record{
        id: record_id,
        kind: :file,
        permissions: [
          %Record{
            id: "unsupported-target-perm",
            kind: :permission,
            raw: %{
              "type" => type,
              "target_id" => "direct-target",
              "access_rights" => ["read"],
              "role" => "reader"
            }
          }
        ]
      }

      log =
        capture_log(fn ->
          assert :ok = ExternalPermissions.apply(record, [doc])
        end)

      assert log =~ ":unsupported_target_type"
      assert log =~ "record #{inspect(record_id)}"
      assert log =~ ~s(role="reader")
      assert permissions_for(doc) == []
    end
  end

  test "prunes stale document grants when record carries a complete permission snapshot" do
    doc = create_document()

    {:ok, stale_team} =
      %Team{}
      |> Team.changeset(%{name: "Stale Team #{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, keep_team} =
      %Team{}
      |> Team.changeset(%{name: "Keep Team #{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, _} = Ingestion.set_document_permission(doc.id, :team, stale_team.id, ["read"])

    record = %Record{
      id: "storage-entry-2",
      kind: :file,
      permissions: [
        %Record{
          id: "keep-team-perm",
          kind: :permission,
          raw: %{
            "type" => "team",
            "target_id" => to_string(keep_team.id),
            "access_rights" => ["read"]
          }
        }
      ]
    }

    assert :ok = ExternalPermissions.apply(record, [doc])

    permissions = permissions_for(doc)
    refute Enum.any?(permissions, &(&1.team_id == stale_team.id))
    assert Enum.any?(permissions, &(&1.team_id == keep_team.id))
  end
end
