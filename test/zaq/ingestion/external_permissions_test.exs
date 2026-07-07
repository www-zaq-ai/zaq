defmodule Zaq.Ingestion.ExternalPermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.PersonChannel
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.ExternalPermissions
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

  defp permission_by_channel(doc, platform, channel_id) do
    permissions_for(doc)
    |> Enum.find(fn permission ->
      Repo.exists?(
        from c in PersonChannel,
          where:
            c.person_id == ^permission.person_id and
              c.platform == ^platform and
              c.channel_identifier == ^channel_id
      )
    end)
  end

  test "imports plain map permission by provider id with default read rights" do
    doc = create_document()

    record = %Record{
      id: "file-1",
      kind: :file,
      attributes: %{provider: "google_drive"},
      permissions: [
        %{id: "provider-user-1", display_name: "Provider User", role: "custom_role"}
      ]
    }

    assert :ok = ExternalPermissions.apply(record, [doc])

    [permission] = permissions_for(doc)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(PersonChannel, [
      %{
        person_id: permission.person_id,
        platform: "google_drive",
        channel_identifier: "provider-user-1",
        display_name: "Provider User",
        inserted_at: now,
        updated_at: now
      }
    ])

    permission = permission_by_channel(doc, "google_drive", "provider-user-1")
    assert permission
    assert permission.access_rights == ["read"]
    assert permission.person.full_name == "Provider User"
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

  test "uses data_source provider fallback when record attributes are not a map" do
    doc = create_document()

    record = %Record{
      id: "file-4",
      kind: :file,
      attributes: nil,
      permissions: [%{"id" => "fallback-user", "display_name" => "Fallback User"}]
    }

    assert :ok = ExternalPermissions.apply(record, [doc])

    [permission] = permissions_for(doc)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(PersonChannel, [
      %{
        person_id: permission.person_id,
        platform: "data_source",
        channel_identifier: "fallback-user",
        display_name: "Fallback User",
        inserted_at: now,
        updated_at: now
      }
    ])

    permission = permission_by_channel(doc, "data_source", "fallback-user")
    assert permission
    assert permission.access_rights == ["read"]
    assert permission.person.full_name == "Fallback User"
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
end
