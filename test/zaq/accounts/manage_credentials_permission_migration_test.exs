unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddManageCredentialsPermission) do
  Code.require_file(
    "../../../priv/repo/migrations/20260917120000_add_manage_credentials_permission.exs",
    __DIR__
  )
end

defmodule Zaq.Accounts.ManageCredentialsPermissionMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.{People, PeoplePermissionGrant, PeoplePermissions}
  alias Zaq.Repo.Migrations.AddManageCredentialsPermission

  @version 20_260_917_120_000
  @opts [log: false, migration_lock: false, skip_table_creation: true]

  test "forward migration preserves grants and down refuses to discard credential grants" do
    Repo.delete_all(PeoplePermissionGrant)
    {:ok, original} = PeoplePermissions.grant(:everyone, :access_profile)
    assert :ok = Ecto.Migrator.down(Repo, @version, AddManageCredentialsPermission, @opts)

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "people_permission_grants_permission_check"}}} =
             Repo.query(
               "INSERT INTO people_permission_grants (scope_type, scope_id, permission, inserted_at, updated_at) VALUES ('team', $1, 'manage_credentials', now(), now())",
               [People.everyone_team().id],
               mode: :savepoint
             )

    assert :ok = Ecto.Migrator.up(Repo, @version, AddManageCredentialsPermission, @opts)
    assert PeoplePermissions.list_grants() == [original]
    {:ok, credential_grant} = PeoplePermissions.grant(:everyone, :manage_credentials)

    assert_raise Ecto.MigrationError, ~r/Revoke manage_credentials/, fn ->
      Ecto.Migrator.down(Repo, @version, AddManageCredentialsPermission, @opts)
    end

    assert PeoplePermissions.list_grants() == [original, credential_grant]
  end
end
