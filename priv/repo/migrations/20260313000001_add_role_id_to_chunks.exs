defmodule Zaq.Repo.Migrations.AddRoleIdToChunks do
  use Ecto.Migration

  def change do
    alter table(:chunks) do
      add :role_id, references(:roles, on_delete: :nilify_all), null: true
    end

    create index(:chunks, [:role_id])
  end
end
