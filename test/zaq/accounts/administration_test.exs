defmodule Zaq.Accounts.AdministrationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts
  alias Zaq.Accounts.Administration

  setup do
    admin =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    regular = user_fixture(%{must_change_password: false})
    %{admin: %{user_id: admin.id}, regular: %{user_id: regular.id}, user: regular}
  end

  test "regular and absent actors cannot create, edit or delete roles", %{regular: regular} do
    role = role_fixture()

    for actor <- [regular, nil, Map.put(regular, :role, %{name: "super_admin"})] do
      for {operation, params} <- [
            {:create_role, %{name: "forbidden"}},
            {:update_role,
             %{id: role.id, attrs: %{meta: %{"permissions" => ["edit_resource_policies"]}}}},
            {:delete_role, %{id: role.id}}
          ] do
        assert Administration.run(actor, operation, params) == {:error, :unauthorized}
      end
    end

    assert Accounts.get_role!(role.id).meta == %{}
    refute Accounts.get_role_by_name("forbidden")
  end

  test "super administrator can create, edit and delete roles", %{admin: admin} do
    assert {:ok, role} = Administration.run(admin, :create_role, %{name: "managed_role"})

    assert {:ok, updated} =
             Administration.run(admin, :update_role, %{
               id: role.id,
               attrs: %{meta: %{"read" => true}}
             })

    assert updated.meta == %{"read" => true}
    assert {:ok, _} = Administration.run(admin, :delete_role, %{id: role.id})
    refute Accounts.get_role_by_name("managed_role")
  end

  test "role assignment is privileged but same-role profile edits remain available", %{
    regular: regular,
    user: user,
    admin: admin
  } do
    target_role = role_fixture(%{name: "super_admin"})
    request = %{id: user.id, attrs: %{role_id: target_role.id}}
    assert Administration.run(regular, :update_user, request) == {:error, :unauthorized}
    assert Accounts.get_user!(user.id).role_id == user.role_id

    assert {:ok, edited} =
             Administration.run(regular, :update_user, %{
               id: user.id,
               attrs: %{username: "profile_edited", role_id: to_string(user.role_id)}
             })

    assert edited.username == "profile_edited"
    assert {:ok, promoted} = Administration.run(admin, :update_user, request)
    assert promoted.role_id == target_role.id
  end

  test "malformed role IDs return validation errors without writing", %{
    regular: actor,
    user: user
  } do
    assert {:error, changeset} =
             Administration.run(actor, :update_user, %{id: user.id, attrs: %{role_id: ""}})

    assert errors_on(changeset).role_id
    assert Accounts.get_user!(user.id).role_id == user.role_id
  end

  test "creation with a role is privileged and stale admin roles are reloaded", %{
    admin: actor,
    regular: regular,
    user: user
  } do
    attrs = %{
      username: "created_admin",
      email: "created_admin@example.com",
      password: "StrongPass1!",
      role_id: user.role_id
    }

    assert Administration.run(regular, :create_user, attrs) == {:error, :unauthorized}
    assert {:ok, _} = Administration.run(actor, :create_user, attrs)
    Accounts.update_user(Accounts.get_user!(actor.user_id), %{role_id: user.role_id})

    assert Administration.run(actor, :create_role, %{name: "stale_admin"}) ==
             {:error, :unauthorized}
  end

  test "only declared operations and valid containers are accepted", %{admin: admin} do
    assert Administration.run(admin, :delete_all, %{}) == {:error, :invalid_operation}
    assert Administration.run(admin, :create_role, []) == {:error, :invalid_request}

    assert Administration.run(admin, :update_role, %{id: "invalid", attrs: %{}}) ==
             {:error, :invalid_request}
  end
end
