defmodule Zaq.Repo.Migrations.AddPublicTag do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :tags, {:array, :string}, default: [], null: false
    end

    create index(:documents, [:tags], using: "GIN")

    create table(:folder_settings) do
      add :volume_name, :string, null: false
      add :folder_path, :string, null: false
      add :tags, {:array, :string}, default: [], null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:folder_settings, [:volume_name, :folder_path])
  end
end
