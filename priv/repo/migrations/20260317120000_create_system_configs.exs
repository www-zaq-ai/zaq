defmodule Zaq.Repo.Migrations.CreateSystemConfigs do
  use Ecto.Migration

  def change do
    create table(:system_configs) do
      add :key, :string, null: false
      add :value, :text

      timestamps()
    end

    create unique_index(:system_configs, [:key])
  end
end
