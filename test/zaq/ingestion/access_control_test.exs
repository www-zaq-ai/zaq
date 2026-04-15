defmodule Zaq.Ingestion.AccessControlTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.{People, Team}
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.SystemConfigFixtures

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})
    :ok
  end

  # Builds a minimal current_user-like map satisfying can_access_file?/2:
  # requires role.name, person_id (integer pointing to a people row), team_ids.
  defp make_current_user(role_name, person_id, team_ids \\ []) do
    %{role: %{name: role_name}, person_id: person_id, team_ids: team_ids}
  end

  defp create_person do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{full_name: "Person #{unique}", email: "p#{unique}@example.com"})

    person
  end

  defp create_team do
    {:ok, team} =
      Repo.insert(Team.changeset(%Team{}, %{name: "team_#{System.unique_integer([:positive])}"}))

    team
  end

  defp unique_source, do: "file_#{System.unique_integer([:positive])}.md"

  setup do
    admin_person = create_person()
    staff_person = create_person()
    super_admin_person = create_person()

    admin = make_current_user("admin", admin_person.id)
    staff = make_current_user("staff", staff_person.id)
    super_admin = make_current_user("super_admin", super_admin_person.id)

    %{
      admin: admin,
      staff: staff,
      super_admin: super_admin,
      admin_person: admin_person,
      staff_person: staff_person
    }
  end

  describe "can_access_file?/2 — no document record" do
    test "returns true when no document exists for the path (backward compat)", %{admin: admin} do
      assert Ingestion.can_access_file?("untracked/file.md", admin)
    end

    test "normalizes leading ./ before lookup", %{admin: admin} do
      assert Ingestion.can_access_file?("./also/untracked.md", admin)
    end
  end

  describe "can_access_file?/2 — public (no permissions set)" do
    test "document with no permissions is accessible to all", %{admin: admin, staff: staff} do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source})

      assert Ingestion.can_access_file?(source, admin)
      assert Ingestion.can_access_file?(source, staff)
    end
  end

  describe "can_access_file?/2 — super admin bypass" do
    test "super admin can access files with permissions set for other person", %{
      super_admin: super_admin,
      admin_person: admin_person
    } do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})

      {:ok, _} =
        Ingestion.set_document_permission(doc.id, :person, admin_person.id, ["read"])

      assert Ingestion.can_access_file?(source, super_admin)
    end

    test "super admin can access files with no permissions", %{super_admin: super_admin} do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source})

      assert Ingestion.can_access_file?(source, super_admin)
    end
  end

  describe "can_access_file?/2 — person permission" do
    test "person with direct permission can access file", %{
      admin: admin,
      admin_person: admin_person
    } do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})

      {:ok, _} =
        Ingestion.set_document_permission(doc.id, :person, admin_person.id, ["read"])

      assert Ingestion.can_access_file?(source, admin)
    end

    test "person without permission cannot access restricted file", %{
      admin_person: admin_person,
      staff: staff
    } do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})

      {:ok, _} =
        Ingestion.set_document_permission(doc.id, :person, admin_person.id, ["read"])

      refute Ingestion.can_access_file?(source, staff)
    end

    test "access is revoked when permission is deleted (doc remains restricted via other permission)",
         %{
           admin: admin,
           admin_person: admin_person
         } do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})
      other_person = create_person()

      {:ok, perm} =
        Ingestion.set_document_permission(doc.id, :person, admin_person.id, ["read"])

      # Add a second permission so the document stays restricted after admin's permission is removed
      {:ok, _} =
        Ingestion.set_document_permission(doc.id, :person, other_person.id, ["read"])

      assert Ingestion.can_access_file?(source, admin)

      {:ok, _} = Ingestion.delete_document_permission(perm.id)

      # With a remaining permission the doc is still restricted — admin no longer has access
      refute Ingestion.can_access_file?(source, admin)
    end
  end

  describe "can_access_file?/2 — team permission" do
    test "person in permitted team can access file", %{staff_person: staff_person} do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})
      team = create_team()

      {:ok, _} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])

      staff_with_team = make_current_user("staff", staff_person.id, [team.id])

      assert Ingestion.can_access_file?(source, staff_with_team)
    end

    test "person not in permitted team cannot access file", %{staff: staff} do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})
      team = create_team()

      {:ok, _} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])

      refute Ingestion.can_access_file?(source, staff)
    end
  end

  describe "list_document_permissions/1" do
    test "returns permissions for a document" do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      perms = Ingestion.list_document_permissions(doc.id)
      assert length(perms) == 1
      assert hd(perms).person_id == person.id
    end

    test "returns empty list when no permissions exist" do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})

      assert Ingestion.list_document_permissions(doc.id) == []
    end
  end

  describe "set_document_permission/4" do
    test "creates a person permission" do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})
      person = create_person()

      assert {:ok, perm} =
               Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert perm.document_id == doc.id
      assert perm.person_id == person.id
      assert perm.access_rights == ["read"]
    end

    test "updates existing permission access_rights" do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert {:ok, updated} =
               Ingestion.set_document_permission(doc.id, :person, person.id, ["read", "write"])

      assert updated.access_rights == ["read", "write"]
      assert length(Ingestion.list_document_permissions(doc.id)) == 1
    end
  end

  describe "delete_document_permission/1" do
    test "deletes a permission by id" do
      source = unique_source()
      {:ok, doc} = Document.upsert(%{source: source})
      person = create_person()

      {:ok, perm} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert {:ok, _} = Ingestion.delete_document_permission(perm.id)
      assert Ingestion.list_document_permissions(doc.id) == []
    end

    test "returns error when permission not found" do
      assert {:error, :not_found} = Ingestion.delete_document_permission(-1)
    end
  end
end
