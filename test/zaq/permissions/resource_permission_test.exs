defmodule Zaq.Permissions.ResourcePermissionTest do
  use Zaq.DataCase, async: true

  alias Zaq.Permissions.ResourcePermission

  describe "valid_rights/0" do
    test "returns all valid rights as a list of strings" do
      rights = ResourcePermission.valid_rights()

      assert is_list(rights)
      assert Enum.all?(rights, &is_binary/1)
      assert "read" in rights
      assert "write" in rights
      assert "update" in rights
      assert "delete" in rights
      assert "run" in rights
      assert "view" in rights
      assert "edit" in rights
      assert "manage" in rights
    end
  end
end
