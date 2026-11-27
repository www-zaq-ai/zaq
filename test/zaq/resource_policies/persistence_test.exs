defmodule Zaq.ResourcePolicies.PersistenceTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Permissions.ResourcePermission
  alias Zaq.Permissions.ResourcePolicy
  alias Zaq.ResourcePolicies
  alias Zaq.ResourcePolicies.ResourceRef

  setup do
    {:ok, person} = People.create_person(%{full_name: "Policy owner"})
    ref = {"person", to_string(person.id)}

    admin =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    %{person: person, actor: %{user_id: admin.id}, ref: ref}
  end

  test "BO creation writes no ACL grants; duplicate Add never overwrites", %{
    actor: actor,
    ref: ref
  } do
    before = Repo.aggregate(ResourcePermission, :count)

    assert {:ok, policy} =
             ResourcePolicies.create(actor, ref, %{classification_level: 2, clearance_level: 4})

    assert {:ok, ^policy} = ResourcePolicies.read(actor, policy.id)
    assert Repo.aggregate(ResourcePermission, :count) == before

    assert {:error, :already_exists} =
             ResourcePolicies.create(actor, ref, %{classification_level: 0})

    assert Repo.get!(ResourcePolicy, policy.id).classification_level == 2
  end

  test "invalid creation leaves no policy or ACL changes", %{actor: actor, ref: ref} do
    before = Repo.aggregate(ResourcePermission, :count)

    assert {:error, %Ecto.Changeset{}} =
             ResourcePolicies.create(actor, ref, %{classification_level: -1})

    assert {:ok, nil} = ResourcePolicies.fetch(ref)
    assert Repo.aggregate(ResourcePermission, :count) == before
  end

  test "authorized versioned edit and reset preserve independent values without ACL changes", %{
    actor: actor,
    ref: ref
  } do
    before = Repo.aggregate(ResourcePermission, :count)

    {:ok, policy} =
      ResourcePolicies.create(actor, ref, %{classification_level: 2, clearance_level: 4})

    assert {:ok, edited} =
             ResourcePolicies.update(actor, policy.id, policy.lock_version, %{
               classification_level: nil
             })

    assert edited.clearance_level == 4
    assert is_nil(edited.classification_level)

    assert {:error, :conflict} =
             ResourcePolicies.update(actor, policy.id, policy.lock_version, %{clearance_level: 0})

    assert {:ok, ^edited} = ResourcePolicies.read(actor, edited.id)
    assert Repo.aggregate(ResourcePermission, :count) == before
  end

  test "target existence is validated after authorization, not inferred from coordinates" do
    admin =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    assert {:error, :not_found} =
             ResourcePolicies.create(%{user_id: admin.id}, {"person", 9_000_000_000}, %{})

    assert {:error, :unauthorized} = ResourcePolicies.create(nil, {"person", 9_000_000_000}, %{})
    assert {:error, :unauthorized} = ResourcePolicies.create(nil, {"document", 12}, %{})
  end

  test "invalid creation requests leave the policy and ACL grants unchanged", %{
    actor: actor,
    ref: ref
  } do
    before = Repo.aggregate(ResourcePermission, :count)

    assert {:error, :invalid_request} = ResourcePolicies.create(actor, ref, nil)
    assert {:error, :invalid_request} = ResourcePolicies.create(actor, ref, %ResourcePolicy{})

    assert {:ok, nil} = ResourcePolicies.fetch(ref)
    assert Repo.aggregate(ResourcePermission, :count) == before
  end

  test "invalid edit requests leave policy values and ACL grants unchanged", %{
    actor: actor,
    ref: ref
  } do
    {:ok, policy} =
      ResourcePolicies.create(actor, ref, %{classification_level: 1, clearance_level: 2})

    before = Repo.aggregate(ResourcePermission, :count)

    assert {:error, :invalid_request} =
             ResourcePolicies.update(actor, policy.id, nil, %{classification_level: 0})

    assert {:error, :invalid_request} =
             ResourcePolicies.update(actor, policy.id, policy.lock_version, nil)

    assert {:ok, persisted} = ResourcePolicies.fetch(ref)
    assert persisted.classification_level == policy.classification_level
    assert persisted.clearance_level == policy.clearance_level
    assert persisted.lock_version == policy.lock_version
    assert Repo.aggregate(ResourcePermission, :count) == before
  end

  test "invalid policy edits return changeset errors without persisting or changing ACL grants",
       %{
         actor: actor,
         ref: ref
       } do
    {:ok, policy} =
      ResourcePolicies.create(actor, ref, %{classification_level: 1, clearance_level: 2})

    before = Repo.aggregate(ResourcePermission, :count)

    assert {:error, %Ecto.Changeset{} = changeset} =
             ResourcePolicies.update(actor, policy.id, policy.lock_version, %{
               classification_level: -1
             })

    classification_errors = errors_on(changeset).classification_level
    assert Enum.any?(classification_errors, &String.contains?(&1, "greater than or equal to"))
    refute Map.has_key?(errors_on(changeset), :lock_version)

    assert {:ok, persisted} = ResourcePolicies.fetch(ref)
    assert persisted.classification_level == policy.classification_level
    assert persisted.lock_version == policy.lock_version
    assert Repo.aggregate(ResourcePermission, :count) == before
  end

  test "reserved default identities can persist and read explicit zero policies", %{actor: actor} do
    before = Repo.aggregate(ResourcePermission, :count)

    for ref <- [ResourceRef.default_agent(), ResourceRef.default_provider()] do
      assert {:ok, policy} = ResourcePolicies.create(actor, ref, %{classification_level: 0})

      {resource_type, "default"} = ref
      assert policy.resource_type == resource_type
      assert policy.resource_id == "default"
      assert policy.classification_level == 0
      assert {:ok, ^policy} = ResourcePolicies.fetch(ref)
      assert {:ok, ^policy} = ResourcePolicies.read(actor, policy.id)
    end

    assert Repo.aggregate(ResourcePermission, :count) == before
  end
end
