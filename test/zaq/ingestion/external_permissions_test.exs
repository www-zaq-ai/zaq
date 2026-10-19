defmodule Zaq.Ingestion.ExternalPermissionsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person, PersonChannel, Team}
  alias Zaq.Contracts.Record
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
