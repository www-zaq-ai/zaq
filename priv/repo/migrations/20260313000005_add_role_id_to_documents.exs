defmodule Zaq.Repo.Migrations.AddRoleIdToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :role_id, references(:roles, on_delete: :nilify_all)
    end
  end
end
