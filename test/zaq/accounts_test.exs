# test/zaq/accounts_test.exs

defmodule Zaq.AccountsTest do
  use Zaq.DataCase

  alias Zaq.Accounts
  alias Zaq.Accounts.{Role, User}

  import Zaq.AccountsFixtures

  describe "roles" do
    test "create_role/1 creates a role" do
      assert {:ok, %Role{name: "test_role"}} = Accounts.create_role(%{name: "test_role"})
    end

    test "create_role/1 with meta" do
      meta = %{"permissions" => ["read", "write"]}
      assert {:ok, %Role{meta: ^meta}} = Accounts.create_role(%{name: "custom", meta: meta})
    end

    test "create_role/1 enforces unique name" do
      role_fixture(%{name: "duplicate"})
      assert {:error, changeset} = Accounts.create_role(%{name: "duplicate"})
      assert {"has already been taken", _} = changeset.errors[:name]
    end

    test "get_role_by_name/1 returns the role" do
      role = role_fixture(%{name: "admin"})
      assert Accounts.get_role_by_name("admin").id == role.id
    end

    test "list_roles/0 returns all roles" do
      role_fixture(%{name: "r1"})
      role_fixture(%{name: "r2"})
      assert length(Accounts.list_roles()) >= 2
    end
  end

  describe "update_user/2" do
    test "updates username" do
      user = user_fixture()
      assert {:ok, updated} = Accounts.update_user(user, %{username: "new_name"})
      assert updated.username == "new_name"
    end

    test "updates role" do
      user = user_fixture()
      new_role = role_fixture(%{name: "new_role"})
      assert {:ok, updated} = Accounts.update_user(user, %{role_id: new_role.id})
      assert updated.role_id == new_role.id
    end

    test "enforces unique username" do
      user1 = user_fixture(%{username: "taken"})
      user2 = user_fixture()
      assert {:error, changeset} = Accounts.update_user(user2, %{username: user1.username})
      assert {"has already been taken", _} = changeset.errors[:username]
    end
  end

  describe "delete_user/1" do
    test "deletes a user" do
      user = user_fixture()
      assert {:ok, _} = Accounts.delete_user(user)
      assert Accounts.get_user_by_username(user.username) == nil
    end
  end

  describe "create_user_with_password/1" do
    test "creates user with hashed password" do
      role = role_fixture()

      assert {:ok, user} =
               Accounts.create_user_with_password(%{
                 username: "withpass",
                 email: "withpass@example.com",
                 role_id: role.id,
                 password: "StrongPass1!"
               })

      assert user.password_hash != nil
      assert user.must_change_password == false
      assert Bcrypt.verify_pass("StrongPass1!", user.password_hash)
    end

    test "rejects short password" do
      role = role_fixture()

      assert {:error, changeset} =
               Accounts.create_user_with_password(%{
                 username: "shortpass",
                 role_id: role.id,
                 password: "short"
               })

      assert "should be at least 8 character(s)" in errors_on(changeset).password
    end
  end

  describe "update_role/2" do
    test "updates role name" do
      role = role_fixture(%{name: "old_name"})
      assert {:ok, updated} = Accounts.update_role(role, %{name: "new_name"})
      assert updated.name == "new_name"
    end

    test "updates role meta" do
      role = role_fixture()
      meta = %{"permissions" => ["admin"]}
      assert {:ok, updated} = Accounts.update_role(role, %{meta: meta})
      assert updated.meta == meta
    end

    test "enforces unique name" do
      role_fixture(%{name: "existing"})
      role2 = role_fixture(%{name: "other"})
      assert {:error, changeset} = Accounts.update_role(role2, %{name: "existing"})
      assert {"has already been taken", _} = changeset.errors[:name]
    end
  end

  describe "delete_role/1" do
    test "deletes a role with no users" do
      role = role_fixture(%{name: "empty_role"})
      assert {:ok, _} = Accounts.delete_role(role)
      assert Accounts.get_role_by_name("empty_role") == nil
    end
  end

  describe "parse_meta/1" do
    test "create_role parses JSON string meta" do
      assert {:ok, role} =
               Accounts.create_role(%{"name" => "json_role", "meta" => ~s({"key": "val"})})

      assert role.meta == %{"key" => "val"}
    end

    test "create_role handles invalid JSON gracefully" do
      assert {:ok, role} = Accounts.create_role(%{"name" => "bad_json", "meta" => "not json"})
      assert role.meta == %{}
    end
  end

  describe "users" do
    test "create_user/1 creates a user" do
      role = role_fixture()

      assert {:ok, %User{}} =
               Accounts.create_user(%{
                 username: "john",
                 email: "john@example.com",
                 role_id: role.id
               })
    end

    test "create_user/1 enforces unique username" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.create_user(%{
                 username: user.username,
                 email: "other@example.com",
                 role_id: user.role_id
               })

      assert {"has already been taken", _} = changeset.errors[:username]
    end

    test "get_user_by_username/1 returns user with role preloaded" do
      user = user_fixture()
      found = Accounts.get_user_by_username(user.username)
      assert found.id == user.id
      assert %Role{} = found.role
    end

    test "list_users/0 returns all users with roles" do
      first_user = user_fixture()
      second_user = user_fixture()
      users = Accounts.list_users()

      usernames = Enum.map(users, & &1.username)

      assert first_user.username in usernames
      assert second_user.username in usernames
      assert Enum.all?(users, fn u -> %Role{} = u.role end)
    end
  end

  describe "change_password/2" do
    test "hashes password and sets must_change_password to false" do
      user = user_fixture()
      assert user.must_change_password == true

      {:ok, updated} = Accounts.change_password(user, %{password: "Newpass123!"})
      assert updated.must_change_password == false
      assert updated.password_hash != nil
      assert Bcrypt.verify_pass("Newpass123!", updated.password_hash)
    end

    test "rejects short passwords" do
      user = user_fixture()
      assert {:error, changeset} = Accounts.change_password(user, %{password: "short"})
      assert "should be at least 8 character(s)" in errors_on(changeset).password
    end
  end

  describe "change_user_password/3" do
    test "allows a user to change their own password with valid current password" do
      user = user_fixture()
      {:ok, user} = Accounts.change_password(user, %{password: "CurrentPass1!"})

      assert {:ok, updated} =
               Accounts.change_user_password(user, user, %{
                 current_password: "CurrentPass1!",
                 new_password: "NextPass1!",
                 new_password_confirmation: "NextPass1!"
               })

      assert Bcrypt.verify_pass("NextPass1!", updated.password_hash)
    end

    test "rejects password change when current password is invalid" do
      user = user_fixture()
      {:ok, user} = Accounts.change_password(user, %{password: "CurrentPass1!"})

      assert {:error, changeset} =
               Accounts.change_user_password(user, user, %{
                 current_password: "WrongPass1!",
                 new_password: "NextPass1!",
                 new_password_confirmation: "NextPass1!"
               })

      assert "is invalid" in errors_on(changeset).current_password
    end

    test "rejects password change when actor edits another user" do
      actor = user_fixture()
      target = user_fixture()
      {:ok, target} = Accounts.change_password(target, %{password: "CurrentPass1!"})

      assert {:error, changeset} =
               Accounts.change_user_password(actor, target, %{
                 current_password: "CurrentPass1!",
                 new_password: "NextPass1!",
                 new_password_confirmation: "NextPass1!"
               })

      assert "you can only change your own password" in errors_on(changeset).new_password
    end

    test "rejects weak new password" do
      user = user_fixture()
      {:ok, user} = Accounts.change_password(user, %{password: "CurrentPass1!"})

      assert {:error, changeset} =
               Accounts.change_user_password(user, user, %{
                 current_password: "CurrentPass1!",
                 new_password: "short",
                 new_password_confirmation: "short"
               })

      assert "should be at least 8 character(s)" in errors_on(changeset).new_password
    end
  end

  describe "authenticate_user/2" do
    test "authenticates user with valid password" do
      user = user_fixture()
      {:ok, user} = Accounts.change_password(user, %{password: "Validpass123!"})

      assert {:ok, authed} = Accounts.authenticate_user(user.username, "Validpass123!")
      assert authed.id == user.id
    end

    test "rejects invalid password" do
      user = user_fixture()
      {:ok, _} = Accounts.change_password(user, %{password: "Validpass123!"})

      assert {:error, :invalid_password} = Accounts.authenticate_user(user.username, "wrong")
    end

    test "returns not_found for unknown username" do
      assert {:error, :not_found} = Accounts.authenticate_user("nobody", "pass")
    end

    test "authenticates super admin with env credentials on first login" do
      Application.put_env(:zaq, :super_admin, username: "superadmin", password: "envpass")
      role = role_fixture(%{name: "super_admin"})

      Accounts.create_user(%{
        username: "superadmin",
        email: "superadmin@zaq.local",
        role_id: role.id,
        must_change_password: true
      })

      assert {:ok, user} = Accounts.authenticate_user("superadmin", "envpass")
      assert user.must_change_password == true

      on_exit(fn -> Application.delete_env(:zaq, :super_admin) end)
    end
  end
end
