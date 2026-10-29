defmodule Zaq.ResourcePolicies.PersistenceTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Permissions.ResourcePermission
  alias Zaq.Permissions.ResourcePolicy
  alias Zaq.ResourcePolicies

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
end
