defmodule Zaq.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  # DDL originally applied by license_manager migration 20260305073414.
  # Uses create_if_not_exists so it is a no-op on shared prod/dev DBs
  # where the table already exists, but creates it in test environments.
  def up do
    create_if_not_exists table(:channels) do
      add :platform, :string, null: false
      add :channel_identifier, :string, null: false
      add :weight, :integer, default: 0
      add :metadata, :map, default: %{}
      add :person_id, references(:people, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:channels, [:person_id, :platform])
    create_if_not_exists index(:channels, [:person_id])
  end

  def down do
    drop_if_exists table(:channels)
  end
end
