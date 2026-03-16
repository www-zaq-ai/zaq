defmodule Zaq.Repo.Migrations.AddSharedRoleIdsToChunks do
  use Ecto.Migration

  def change do
    alter table(:chunks) do
      add :shared_role_ids, {:array, :integer}, default: []
    end
  end
end
