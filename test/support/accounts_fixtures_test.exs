defmodule Zaq.AccountsFixturesTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures

  alias Zaq.Accounts.Role
  alias Zaq.Repo

  test "role_fixture/1 reuses an existing role name" do
    existing = role_fixture(%{name: "ops"})
    reused = role_fixture(%{name: "ops"})

    assert existing.id == reused.id
  end

  test "user_fixture creates with explicit role" do
    role = role_fixture(%{name: "fixture_staff"})
    user = user_fixture(%{role: role, username: "fixture_user"})

    assert user.username == "fixture_user"
    assert user.role_id == role.id
  end

  test "super_admin_fixture/admin_fixture/staff_fixture create expected role names" do
    super_admin = super_admin_fixture()
    admin = admin_fixture()
    staff = staff_fixture()

    assert Repo.get(Role, super_admin.role_id).name == "super_admin"
    assert Repo.get(Role, admin.role_id).name == "admin"
    assert Repo.get(Role, staff.role_id).name == "staff"
  end
end
