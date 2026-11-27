defmodule Zaq.Repo.Migrations.CreateResourcePolicies do
  use Ecto.Migration

  def up do
    create table(:resource_policies) do
      add :resource_type, :text, null: false
      add :resource_id, :text, null: false
      add :classification_level, :integer
      add :clearance_level, :integer
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:resource_policies, [:resource_type, :resource_id],
             name: :resource_policies_target_index
           )

    create constraint(:resource_policies, :resource_policies_classification_nonnegative,
             check: "classification_level >= 0"
           )

    create constraint(:resource_policies, :resource_policies_clearance_nonnegative,
             check: "clearance_level >= 0"
           )
  end

  def down do
    execute(fn ->
      schema = String.replace(prefix() || "public", "\"", "\"\"")
      table = ~s("#{schema}"."resource_policies")
      repo().query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")

      if repo().query!("SELECT 1 FROM #{table} LIMIT 1").num_rows > 0 do
        raise Ecto.MigrationError,
              "Cannot roll back nonempty resource policies; use a policy-aware forward migration"
      end
    end)

    drop table(:resource_policies)
  end
end
