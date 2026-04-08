defmodule Zaq.Repo.Migrations.AddTeamIdIndexToDocumentPermissions do
  use Ecto.Migration

  def change do
    create index(:document_permissions, [:team_id])
  end
end
