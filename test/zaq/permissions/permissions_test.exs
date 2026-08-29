defmodule Zaq.PermissionsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Mox
  setup :verify_on_exit!

  alias Zaq.Accounts.People
  alias Zaq.Engine.Workflows.Workflow
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.Permissions.PermissionRevokerMock
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

    test "nil person can read an Everyone-granted resource but not other team grants" do
      workflow = fake_workflow()
      team = create_team()

      {:ok, _} = Permissions.grant(workflow, %{team_id: team.id, access_rights: ["read"]})
      refute Permissions.can?(nil, :read, workflow)

      {:ok, _} = Permissions.grant_public(workflow)
      assert Permissions.can?(nil, :read, workflow)
    end

    test "inherited ancestor grants are effective for child resources" do
      parent = fake_workflow()
      child = fake_document()

      {:ok, _} = Permissions.grant_public(parent)

      assert Permissions.can?(nil, :read, child, ancestors: [parent])
      assert Permissions.public?(child, ancestors: [parent])
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

    test "returns the revoker changeset and leaves the row intact" do
      person = create_person()
      workflow = fake_workflow()
      {:ok, perm} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})
      changeset = ResourcePermission.changeset(perm, %{}) |> add_error(:base, "cannot revoke")

      expect(PermissionRevokerMock, :delete, fn ^perm -> {:error, changeset} end)

      assert {:error, ^changeset} =
               Permissions.revoke(workflow, perm, revoker: PermissionRevokerMock)

      assert Repo.get(ResourcePermission, perm.id)
    end
  end

  describe "revoke_public/2" do
    test "is a no-op when no public grant exists" do
      workflow = fake_workflow()
      team = create_team()

      {:ok, permission} =
        Permissions.grant(workflow, %{team_id: team.id, access_rights: ["read"]})

      assert :ok = Permissions.revoke_public(workflow)
      assert Repo.get(ResourcePermission, permission.id)
    end

    test "removes the public grant without removing private grants" do
      workflow = fake_workflow()
      team = create_team()

      {:ok, private_permission} =
        Permissions.grant(workflow, %{team_id: team.id, access_rights: ["read"]})

      {:ok, public_permission} = Permissions.grant_public(workflow)
      assert Permissions.public?(workflow)
      assert Permissions.can?(nil, :read, workflow)

      assert :ok = Permissions.revoke_public(workflow)
      refute Permissions.public?(workflow)
      refute Permissions.can?(nil, :read, workflow)
      assert Repo.get(ResourcePermission, private_permission.id)
      assert Repo.get(ResourcePermission, public_permission.id) == nil
    end
  end

  describe "replace/3 rollback" do
    test "restores all original grants when a deletion fails" do
      workflow = fake_workflow()
      person = create_person()
      team = create_team()
      {:ok, first} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})
      {:ok, second} = Permissions.grant(workflow, %{team_id: team.id, access_rights: ["view"]})
      changeset = ResourcePermission.changeset(second, %{}) |> add_error(:base, "cannot revoke")

      expect(PermissionRevokerMock, :delete, 2, fn permission ->
        case Process.get(:permission_revocations, 0) do
          0 ->
            Process.put(:permission_revocations, 1)
            Repo.delete(permission)

          _ ->
            {:error, changeset}
        end
      end)

      desired_person = create_person()

      assert {:error, ^changeset} =
               Permissions.replace(
                 workflow,
                 [%{person_id: desired_person.id, access_rights: ["read"]}],
                 revoker: PermissionRevokerMock
               )

      permissions = Permissions.list(workflow)

      assert Enum.map(permissions, & &1.id) |> Enum.sort() ==
               Enum.map([first, second], & &1.id) |> Enum.sort()

      assert Enum.map(permissions, &{&1.person_id, &1.team_id, &1.access_rights}) |> Enum.sort() ==
               Enum.map([first, second], &{&1.person_id, &1.team_id, &1.access_rights})
               |> Enum.sort()
    end
  end

  describe "count_principals/1" do
    test "counts distinct person and team principals across resources with one query" do
      person = create_person()
      other_person = create_person()
      team = create_team()
      first = fake_workflow()
      second = fake_workflow()
      unrelated = fake_document()

      {:ok, _} = Permissions.grant(first, %{person_id: person.id, access_rights: ["read"]})
      {:ok, _} = Permissions.grant(second, %{person_id: person.id, access_rights: ["run"]})
      {:ok, _} = Permissions.grant(first, %{team_id: team.id, access_rights: ["view"]})

      {:ok, _} =
        Permissions.grant(unrelated, %{person_id: other_person.id, access_rights: ["read"]})

      assert {2, [_query]} =
               capture_resource_permission_queries(fn ->
                 Permissions.count_principals([first, second, first])
               end)
    end

    test "query capture ignores concurrent resource permission telemetry" do
      person = create_person()
      workflow = fake_workflow()

      {:ok, _} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["read"]})

      assert {1, [_query]} =
               capture_resource_permission_queries(fn ->
                 task =
                   Task.async(fn ->
                     :telemetry.execute(
                       [:zaq, :repo, :query],
                       %{},
                       %{source: "resource_permissions", query: "SELECT leaked"}
                     )
                   end)

                 Task.await(task)
                 Permissions.count_principals([workflow])
               end)
    end

    test "keeps person and team identifiers in separate namespaces" do
      person = create_person()
      team = create_team()
      workflow = fake_workflow()

      {:ok, _} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["read"]})
      {:ok, _} = Permissions.grant(workflow, %{team_id: team.id, access_rights: ["read"]})

      assert Permissions.count_principals([workflow]) == 2
    end

    test "returns zero without querying when no resources are provided" do
      assert {0, []} =
               capture_resource_permission_queries(fn -> Permissions.count_principals([]) end)
    end
  end

  property "count_principals/1 is stable when resource inputs are duplicated" do
    check all(duplicate_count <- integer(1..5), max_runs: 10) do
      person = create_person()
      team = create_team()
      workflow = fake_workflow()

      {:ok, _} = Permissions.grant(workflow, %{person_id: person.id, access_rights: ["read"]})
      {:ok, _} = Permissions.grant(workflow, %{team_id: team.id, access_rights: ["read"]})

      resources = List.duplicate(workflow, duplicate_count)

      assert Permissions.count_principals(resources) == 2
    end
  end

  property "replace/2 is atomic for an invalid grant after a valid prefix" do
    check all(valid_prefix_length <- integer(0..3), max_runs: 10) do
      workflow = fake_workflow()
      person = create_person()

      {:ok, original} =
        Permissions.grant(workflow, %{person_id: person.id, access_rights: ["run"]})

      valid_prefix =
        for _ <- Enum.take(1..3, valid_prefix_length) do
          team = create_team()

          %{team_id: team.id, access_rights: ["read"]}
        end

      desired = valid_prefix ++ [%{access_rights: ["read"]}]

      assert {:error, changeset} = Permissions.replace(workflow, desired)
      assert changeset.errors[:person_id]
      assert Repo.get(ResourcePermission, original.id).access_rights == ["run"]
      assert Enum.map(Permissions.list(workflow), & &1.id) == [original.id]
    end
  end

  defp capture_resource_permission_queries(fun) do
    handler_id = {__MODULE__, :resource_permission_queries, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:zaq, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata[:source] == "resource_permissions" do
            send(test_pid, {:resource_permission_query, metadata[:query]})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, collect_resource_permission_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_resource_permission_queries(queries) do
    receive do
      {:resource_permission_query, query} ->
        collect_resource_permission_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
