unless Code.ensure_loaded?(Zaq.Repo.Migrations.CreateResourcePolicies) do
  Code.require_file(
    "../../../priv/repo/migrations/20261023000000_create_resource_policies.exs",
    __DIR__
  )
end

defmodule Zaq.Permissions.ResourcePolicyMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Permissions.ResourcePolicy
  alias Zaq.Repo.Migrations.CreateResourcePolicies

  test "rollback refuses to discard persisted confidentiality policies" do
    {:ok, policy} =
      %ResourcePolicy{}
      |> ResourcePolicy.changeset(%{
        resource_type: "storage_entry",
        resource_id: "00000000-0000-4000-8000-000000000012",
        classification_level: 4
      })
      |> Repo.insert()

    assert_raise Ecto.MigrationError, ~r/nonempty resource policies/, fn ->
      Ecto.Migrator.down(Repo, 20_261_023_000_000, CreateResourcePolicies,
        log: false,
        migration_lock: false,
        skip_table_creation: true
      )
    end

    assert Repo.get!(ResourcePolicy, policy.id).classification_level == 4
  end
end
