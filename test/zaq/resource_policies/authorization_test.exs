defmodule Zaq.ResourcePolicies.AuthorizationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Permissions
  alias Zaq.Permissions.ResourcePolicy
  alias Zaq.ResourcePolicies

  setup do
    {:ok, person} = People.create_person(%{full_name: "Policy subject"})

    policy =
      %ResourcePolicy{}
      |> ResourcePolicy.changeset(%{
        resource_type: "person",
        resource_id: to_string(person.id),
        clearance_level: 2_147_483_647
      })
      |> Repo.insert!()

    %{person: person, actor: %{person: %{id: person.id}}, policy: policy}
  end

  test "Person and portal actors cannot administer policies regardless of grants or clearance", %{
    actor: actor,
    person: person,
    policy: policy
  } do
    {:ok, team} = People.create_team(%{name: "Cleared team"})
    {:ok, person} = People.update_person(person, %{team_ids: [team.id]})

    # Even persisted grants from the superseded WIP model confer no administration.
    for resource <- [person, policy, {"resource_policy_scope", "global"}] do
      {:ok, _} =
        Permissions.grant(resource, %{
          person_id: person.id,
          access_rights: ["read", "write", "edit", "manage"]
        })

      {:ok, _} =
        Permissions.grant(resource, %{team_id: team.id, access_rights: ["manage"]})
    end

    assert Permissions.can?(person, :manage, person)
    assert Permissions.can?(person, :manage, policy)

    for principal <- [
          actor,
          %{kind: :person, subject: to_string(person.id), person_id: person.id},
          Map.merge(actor, %{skip_permissions: true, skip_actor_clearance: true}),
          nil
        ] do
      assert ResourcePolicies.read(principal, policy.id) == {:error, :unauthorized}

      assert ResourcePolicies.create(principal, person, %{clearance_level: 0}) ==
               {:error, :unauthorized}

      assert ResourcePolicies.update(principal, policy.id, policy.lock_version, %{
               clearance_level: nil
             }) == {:error, :unauthorized}
    end

    assert Repo.get!(ResourcePolicy, policy.id) == policy
  end

  test "BO view authority is independent of editing and is reloaded after revocation", %{
    policy: policy
  } do
    role = role_fixture(%{meta: %{"permissions" => ["view_resource_policies"]}})
    user = user_fixture(%{role: role, must_change_password: false})
    actor = %{kind: :bo_user, subject: to_string(user.id), user_id: user.id}

    assert {:ok, ^policy} = ResourcePolicies.read(actor, policy.id)

    assert ResourcePolicies.update(actor, policy.id, policy.lock_version, %{clearance_level: 0}) ==
             {:error, :unauthorized}

    {:ok, _} = Accounts.update_role(role, %{meta: %{}})
    assert ResourcePolicies.read(actor, policy.id) == {:error, :unauthorized}
  end

  test "add-only BO capability cannot read or overwrite an existing policy", %{person: person} do
    {:ok, target} = People.create_person(%{full_name: "New policy subject"})
    role = role_fixture(%{meta: %{"permissions" => ["add_resource_policies"]}})
    user = user_fixture(%{role: role, must_change_password: false})
    actor = %{user_id: user.id, person: %{id: person.id}}

    assert {:ok, policy} = ResourcePolicies.create(actor, target, %{clearance_level: 4})
    assert ResourcePolicies.read(actor, policy.id) == {:error, :unauthorized}

    assert ResourcePolicies.update(actor, policy.id, policy.lock_version, %{clearance_level: 0}) ==
             {:error, :unauthorized}

    assert ResourcePolicies.create(actor, target, %{clearance_level: 0}) ==
             {:error, :already_exists}

    assert Repo.get!(ResourcePolicy, policy.id).clearance_level == 4
  end

  test "edit-only BO capability permits versioned reset but not read or add", %{
    policy: policy,
    person: person
  } do
    role = role_fixture(%{meta: %{"permissions" => ["edit_resource_policies"]}})
    user = user_fixture(%{role: role, must_change_password: false})
    actor = %{user_id: user.id}
    assert ResourcePolicies.read(actor, policy.id) == {:error, :unauthorized}
    assert ResourcePolicies.create(actor, person, %{}) == {:error, :unauthorized}

    assert {:ok, updated} =
             ResourcePolicies.update(actor, policy.id, policy.lock_version, %{
               clearance_level: nil
             })

    assert is_nil(updated.clearance_level)
    assert updated.lock_version == policy.lock_version + 1
    {:ok, _} = Accounts.update_role(role, %{meta: %{}})

    assert ResourcePolicies.update(actor, updated.id, updated.lock_version, %{clearance_level: 0}) ==
             {:error, :unauthorized}
  end
end
