defmodule Zaq.Accounts.PermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts
  alias Zaq.Accounts.Permissions
  import Zaq.AccountsFixtures

  # user_fixture doesn't preload :role — reload via Accounts to get the full struct
  defp loaded_user(user), do: Accounts.get_user!(user.id)

  describe "list_accessible_role_ids/1" do
    test "returns own role_id when no cross-role access configured" do
      user = user_fixture() |> loaded_user()
      assert Permissions.list_accessible_role_ids(user) == [user.role_id]
    end

    test "returns only own role_id regardless of meta accessible_role_ids" do
      role_b = role_fixture()
      role_a = role_fixture(%{meta: %{"accessible_role_ids" => [role_b.id]}})
      user = user_fixture(%{role: role_a}) |> loaded_user()

      ids = Permissions.list_accessible_role_ids(user)
      assert user.role_id in ids
      refute role_b.id in ids
    end

    test "returns empty list when user has no role" do
      user = user_fixture() |> loaded_user()
      user_without_role = %{user | role_id: nil, role: nil}
      assert Permissions.list_accessible_role_ids(user_without_role) == []
    end

    test "deduplicates ids" do
      role = role_fixture()
      user = user_fixture(%{role: role}) |> loaded_user()
      user_with_dupe = %{user | role: %{user.role | meta: %{"accessible_role_ids" => [role.id]}}}

      assert Permissions.list_accessible_role_ids(user_with_dupe) == [user.role_id]
    end

    test "ignores string ids in meta" do
      role_b = role_fixture()
      role_a = role_fixture(%{meta: %{"accessible_role_ids" => ["#{role_b.id}"]}})
      user = user_fixture(%{role: role_a}) |> loaded_user()

      ids = Permissions.list_accessible_role_ids(user)
      refute role_b.id in ids
      assert user.role_id in ids
    end
  end

  describe "can_retrieve?/1 and can_ingest?/1" do
    test "returns true when user has a role" do
      user = user_fixture()
      assert Permissions.can_retrieve?(user)
      assert Permissions.can_ingest?(user)
    end

    test "returns false when user has no role" do
      user = user_fixture()
      user_without_role = %{user | role_id: nil}
      refute Permissions.can_retrieve?(user_without_role)
      refute Permissions.can_ingest?(user_without_role)
    end
  end
end
