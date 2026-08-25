defmodule Zaq.Repo.Migrations.CreateStorageEntries do
  use Ecto.Migration

  def change do
    create table(:storage_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :volume, :string, null: false
      add :relative_path, :string, null: false
      add :parent_id, references(:storage_entries, type: :binary_id, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:storage_entries, [:volume, :relative_path],
             where: "deleted_at IS NULL",
             name: :storage_entries_active_path_index
           )

    create index(:storage_entries, [:parent_id])
  end
end
