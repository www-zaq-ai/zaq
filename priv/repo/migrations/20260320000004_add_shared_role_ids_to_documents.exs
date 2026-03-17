defmodule Zaq.Repo.Migrations.AddSharedRoleIdsToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :shared_role_ids, {:array, :integer}, default: [], null: false
    end
  end
end
