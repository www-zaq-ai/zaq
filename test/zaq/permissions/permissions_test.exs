defmodule Zaq.PermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Engine.Workflows.Workflow
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.Permissions.ResourcePermission

  defp create_person do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{"full_name" => "Person #{unique}", "email" => "p#{unique}@test.com"})

    person
  end

  defp create_team do
    {:ok, team} = People.create_team(%{name: "Team #{System.unique_integer([:positive])}"})
    team
  end

  defp fake_workflow(id \\ Ecto.UUID.generate()), do: %Workflow{id: id}
  defp fake_document(id \\ System.unique_integer([:positive])), do: %Document{id: id}

  describe "grant/3" do
    test "inserts a person permission row" do
      person = create_person()
      workflow = fake_workflow()

      assert {:ok, perm} =
               Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})

      assert perm.resource_type == "workflow"
      assert perm.resource_id == workflow.id
      assert perm.person_id == person.id
      assert perm.access_rights == ["run"]
    end

    test "inserts a team permission row" do
      team = create_team()
      workflow = fake_workflow()

      assert {:ok, perm} =
               Permissions.grant(workflow, %{team_id: team.id, access_rights: ["view"]})

      assert perm.resource_type == "workflow"
      assert perm.team_id == team.id
    end

    test "upserts — updates access_rights when permission already exists" do
      person = create_person()
      workflow = fake_workflow()

      {:ok, _} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["view"]})

      {:ok, perm} =
        Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run", "view"]})

      assert perm.access_rights == ["run", "view"]
    end

    test "returns changeset error when neither person_id nor team_id given" do
      workflow = fake_workflow()
      assert {:error, changeset} = Permissions.grant(workflow, %{access_rights: ["run"]})
      assert changeset.errors[:person_id]
    end
  end

  describe "revoke/3" do
    test "deletes the permission row" do
      person = create_person()
      workflow = fake_workflow()

      {:ok, perm} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})
      assert :ok = Permissions.revoke(workflow, perm)
      assert Repo.get(ResourcePermission, perm.id) == nil
    end
  end

  describe "can?/4" do
    test "returns false for nil person regardless of resource" do
      workflow = fake_workflow()
      refute Permissions.can?(nil, :run, workflow)
    end

    test "nil person with skip_permissions: true returns true" do
      workflow = fake_workflow()
      assert Permissions.can?(nil, :run, workflow, skip_permissions: true)
    end

    test "returns true for a direct person grant" do
      person = create_person()
      workflow = fake_workflow()
      {:ok, _} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})

      assert Permissions.can?(person, :run, workflow)
    end

    test "returns false when person has no grant" do
      person = create_person()
      workflow = fake_workflow()

      refute Permissions.can?(person, :run, workflow)
    end

    test "returns false for wrong right" do
      person = create_person()
      workflow = fake_workflow()
      {:ok, _} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["view"]})

      refute Permissions.can?(person, :run, workflow)
    end

    test "returns true for a team grant when person belongs to team" do
      person = create_person()
      team = create_team()
      {:ok, person} = People.assign_team(person, team.id)
      workflow = fake_workflow()
      {:ok, _} = Permissions.grant(workflow, %{team_id: team.id, access_rights: ["run"]})

      assert Permissions.can?(person, :run, workflow)
    end

    test "returns false for team grant when person is not in team" do
      person = create_person()
      team = create_team()
      workflow = fake_workflow()
      {:ok, _} = Permissions.grant(workflow, %{team_id: team.id, access_rights: ["run"]})

      refute Permissions.can?(person, :run, workflow)
    end

    test "skip_permissions: true always returns true for a real person" do
      person = create_person()
      workflow = fake_workflow()

      assert Permissions.can?(person, :run, workflow, skip_permissions: true)
    end
  end

  describe "list/2" do
    test "returns all permissions for the resource" do
      person = create_person()
      team = create_team()
      workflow = fake_workflow()

      {:ok, _} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})
      {:ok, _} = Permissions.grant(workflow, %{team_id: team.id, access_rights: ["view"]})

      perms = Permissions.list(workflow)
      assert length(perms) == 2
    end

    test "returns empty list when no permissions exist" do
      workflow = fake_workflow()
      assert Permissions.list(workflow) == []
    end
  end

  # --- Polymorphic resource types ---

  describe "grant/3 with document resource" do
    test "derives resource_type 'document' from Document struct" do
      person = create_person()
      doc = fake_document()

      assert {:ok, perm} =
               Permissions.grant(doc, %{person_id: person.id, access_rights: ["read"]})

      assert perm.resource_type == "document"
      assert perm.resource_id == to_string(doc.id)
      assert perm.access_rights == ["read"]
    end
  end

  describe "can?/4 with document resource" do
    test "returns true when person has a read grant on a document" do
      person = create_person()
      doc = fake_document()
      {:ok, _} = Permissions.grant(doc, %{person_id: person.id, access_rights: ["read"]})

      assert Permissions.can?(person, :read, doc)
    end

    test "returns false when person has no grant on the document" do
      person = create_person()
      doc = fake_document()

      refute Permissions.can?(person, :read, doc)
    end
  end

  describe "revoke/3 error propagation" do
    test "returns :ok when row is successfully deleted" do
      person = create_person()
      workflow = fake_workflow()
      {:ok, perm} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})

      assert :ok = Permissions.revoke(workflow, perm)
    end
  end
end
