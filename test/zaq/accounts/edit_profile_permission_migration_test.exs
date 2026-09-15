unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddEditProfilePermission) do
  Code.require_file(
    "../../../priv/repo/migrations/20260914153303_add_edit_profile_permission.exs",
    __DIR__
  )
end

defmodule Zaq.Accounts.EditProfilePermissionMigrationTest do
  use Zaq.DataCase, async: false
  alias Zaq.Accounts.{PeoplePermissionGrant, PeoplePermissions}
  alias Zaq.Repo.Migrations.AddEditProfilePermission
  @version 20_260_914_153_303
  @opts [log: false, migration_lock: false, skip_table_creation: true]

  test "forward migration preserves historical grants and down refuses to discard edit grants" do
    Repo.delete_all(PeoplePermissionGrant)
    {:ok, original} = PeoplePermissions.grant(:all_people, :access_profile)
    assert :ok = Ecto.Migrator.down(Repo, @version, AddEditProfilePermission, @opts)

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "people_permission_grants_permission_check"}}} =
             Repo.query(
               "INSERT INTO people_permission_grants (scope_type, permission, inserted_at, updated_at) VALUES ('all_people', 'edit_profile', now(), now())",
               [],
               mode: :savepoint
             )

    assert :ok = Ecto.Migrator.up(Repo, @version, AddEditProfilePermission, @opts)
    assert PeoplePermissions.list_grants() == [original]
    {:ok, edit} = PeoplePermissions.grant(:all_people, :edit_profile)

    assert_raise Ecto.MigrationError, ~r/Revoke edit_profile/, fn ->
      Ecto.Migrator.down(Repo, @version, AddEditProfilePermission, @opts)
    end

    assert PeoplePermissions.list_grants() == [original, edit]
  end
end
