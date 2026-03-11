defmodule Zaq.Accounts.SuperAdminSeederTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts
  alias Zaq.Accounts.Role
  alias Zaq.Accounts.SuperAdminSeeder
  alias Zaq.Accounts.User
  alias Zaq.Repo

  import Ecto.Query

  setup do
    Zaq.Repo.delete_all(Zaq.Accounts.Role)
    original_skip = Application.get_env(:zaq, :skip_super_admin_seed)
    original_super_admin = Application.get_env(:zaq, :super_admin)

    on_exit(fn ->
      if is_nil(original_skip) do
        Application.delete_env(:zaq, :skip_super_admin_seed)
      else
        Application.put_env(:zaq, :skip_super_admin_seed, original_skip)
      end

      if is_nil(original_super_admin) do
        Application.delete_env(:zaq, :super_admin)
      else
        Application.put_env(:zaq, :super_admin, original_super_admin)
      end
    end)

    :ok
  end

  test "init/1 does nothing when seeding is skipped" do
    Application.put_env(:zaq, :skip_super_admin_seed, true)

    assert :ignore = SuperAdminSeeder.init([])
    assert Accounts.list_roles() == []
  end

  test "init/1 creates base roles and super admin when configured" do
    Application.put_env(:zaq, :skip_super_admin_seed, false)
    Application.put_env(:zaq, :super_admin, username: "root", password: "secret")

    assert :ignore = SuperAdminSeeder.init([])

    assert Accounts.get_role_by_name("super_admin")
    assert Accounts.get_role_by_name("admin")
    assert Accounts.get_role_by_name("staff")

    user = Accounts.get_user_by_username("root")
    assert user
    assert user.must_change_password == true
    assert user.role.name == "super_admin"
  end

  test "init/1 creates only roles when super_admin config is missing" do
    Application.put_env(:zaq, :skip_super_admin_seed, false)
    Application.delete_env(:zaq, :super_admin)

    assert :ignore = SuperAdminSeeder.init([])

    assert Accounts.get_role_by_name("super_admin")
    assert Accounts.get_user_by_username("root") == nil
  end

  test "init/1 is idempotent when user and roles already exist" do
    Application.put_env(:zaq, :skip_super_admin_seed, false)
    Application.put_env(:zaq, :super_admin, username: "root", password: "secret")

    assert :ignore = SuperAdminSeeder.init([])
    assert :ignore = SuperAdminSeeder.init([])

    assert Repo.aggregate(from(r in Role, where: r.name == "super_admin"), :count) == 1
    assert Repo.aggregate(from(r in Role, where: r.name == "admin"), :count) == 1
    assert Repo.aggregate(from(r in Role, where: r.name == "staff"), :count) == 1

    assert Repo.aggregate(from(u in User, where: u.username == "root"), :count) == 1
  end

  test "init/1 does not recreate pre-existing super admin user" do
    Application.put_env(:zaq, :skip_super_admin_seed, false)
    Application.put_env(:zaq, :super_admin, username: "root", password: "secret")

    assert :ignore = SuperAdminSeeder.init([])

    existing = Accounts.get_user_by_username("root")
    assert existing

    assert :ignore = SuperAdminSeeder.init([])

    reloaded = Accounts.get_user_by_username("root")
    assert reloaded.id == existing.id
  end
end
