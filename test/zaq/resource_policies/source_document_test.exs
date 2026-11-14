defmodule Zaq.ResourcePolicies.SourceDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.Permissions.{ResourcePermission, ResourcePolicy}
  alias Zaq.ResourcePolicies
  alias Zaq.ResourcePolicies.ResourceRef
  alias Zaq.Storage.{EntryCatalog, StorageEntry}

  setup do
    admin =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    {:ok, person} = People.create_person(%{full_name: "Policy subject"})

    %{admin: %{user_id: admin.id}, person: person}
  end

  test "never-ingested files and folders have the same targets as source permissions", %{
    person: person
  } do
    document_count = Repo.aggregate(Document, :count)

    for {path, kind} <- [{"documents", :directory}, {"documents/report.txt", :file}] do
      {:ok, entry} = EntryCatalog.ensure("source-policy-test", path, kind)
      resource = %StorageEntry{id: entry.id}
      assert {:ok, ref} = ResourceRef.new(resource)
      assert ref == {"storage_entry", entry.id}

      assert {:ok, grant} =
               Permissions.grant(resource, %{person_id: person.id, access_rights: ["read"]})

      assert ref == {grant.resource_type, grant.resource_id}
      assert Permissions.can?(person, :read, resource)
      assert ResourceRef.new(resource) == ResourceRef.new(ref)
    end

    assert Repo.aggregate(Document, :count) == document_count
    refute ResourcePolicies.ready?()
  end

  test "a valid source identity alone does not enable creation or edits", %{
    admin: admin
  } do
    {:ok, entry} = EntryCatalog.ensure("source-policy-test", "report.txt", :file)
    ref = {"storage_entry", entry.id}
    policy_count = Repo.aggregate(ResourcePolicy, :count)
    grant_count = Repo.aggregate(ResourcePermission, :count)

    for target <- [ref, %StorageEntry{id: entry.id}] do
      assert ResourcePolicies.create(admin, target, %{classification_level: 0}) ==
               {:error, :unresolved_source}
    end

    assert Repo.aggregate(ResourcePolicy, :count) == policy_count
    assert Repo.aggregate(ResourcePermission, :count) == grant_count

    policy = insert_policy(ref, 8)

    for value <- [0, nil] do
      assert ResourcePolicies.update(admin, policy.id, policy.lock_version, %{
               classification_level: value
             }) == {:error, :unresolved_source}
    end

    assert Repo.get!(ResourcePolicy, policy.id).classification_level == 8
  end

  test "source-backed ingestion rows cannot introduce competing policies even with full authority",
       %{
         admin: admin,
         person: person
       } do
    {:ok, entry} = EntryCatalog.ensure("source-policy-test", "protected.txt", :file)
    source_ref = {"storage_entry", entry.id}
    source_policy = insert_policy(source_ref, 8)

    {:ok, document} =
      Document.create(%{
        source: "source-policy-test/protected.txt",
        metadata: %{"provider" => "disk", "provider_record_id" => entry.id}
      })

    # Existing ingestion-row permissions are unchanged; they are not policy identity.
    {:ok, grant} =
      Permissions.grant(document, %{person_id: person.id, access_rights: ["read", "manage"]})

    assert grant.resource_type == "document"
    assert grant.resource_id == to_string(document.id)
    assert Permissions.can?(person, :read, document)
    policy_count = Repo.aggregate(ResourcePolicy, :count)
    grant_count = Repo.aggregate(ResourcePermission, :count)

    for target <- [document, {"document", document.id}, {"document", to_string(document.id)}],
        value <- [0, nil, 2] do
      assert ResourcePolicies.create(admin, target, %{
               classification_level: value,
               clearance_level: value
             }) == {:error, :unresolved_source}
    end

    assert ResourcePolicies.fetch(document) == {:error, :unresolved_source}
    assert ResourcePolicies.fetch({"document", document.id}) == {:error, :unresolved_source}
    assert Repo.aggregate(ResourcePolicy, :count) == policy_count
    assert Repo.aggregate(ResourcePermission, :count) == grant_count
    assert {:ok, ^source_policy} = ResourcePolicies.fetch(source_ref)
  end

  test "changeset and privileged reads/edits reject independently persisted ingestion policies",
       %{
         admin: admin
       } do
    {:ok, document} = Document.create(%{source: "data_source/google_drive/12/stable-id"})
    ref = {"document", to_string(document.id)}

    for value <- [0, nil] do
      changeset =
        ResourcePolicy.changeset(%ResourcePolicy{}, %{
          resource_type: "document",
          resource_id: elem(ref, 1),
          classification_level: value
        })

      refute changeset.valid?
      assert errors_on(changeset).resource_id
    end

    # Model a WIP row inserted outside the validated changeset, not a migration path.
    policy = insert_policy(ref, 8)

    assert ResourcePolicies.read(admin, policy.id) == {:error, :unresolved_source}

    for value <- [0, nil] do
      assert ResourcePolicies.update(admin, policy.id, policy.lock_version, %{
               classification_level: value,
               clearance_level: value
             }) == {:error, :unresolved_source}
    end

    assert Repo.get!(ResourcePolicy, policy.id) == policy
  end

  test "an ingestion source path or unsigned provider metadata is not a binding" do
    for attrs <- [
          %{source: "source-policy-test/report.txt"},
          %{
            source: "data_source/google_drive/12/stable-id",
            metadata: %{
              "provider" => "google_drive",
              "provider_config_id" => "12",
              "provider_file_id" => "stable-id"
            }
          }
        ] do
      {:ok, document} = Document.create(attrs)
      assert ResourcePolicies.fetch(document) == {:error, :unresolved_source}
    end
  end

  defp insert_policy({type, id}, level) do
    %ResourcePolicy{}
    |> change(%{
      resource_type: type,
      resource_id: id,
      classification_level: level,
      clearance_level: level
    })
    |> Repo.insert!()
  end
end
