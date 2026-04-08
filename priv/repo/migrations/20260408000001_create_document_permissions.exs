defmodule Zaq.Repo.Migrations.CreateDocumentPermissions do
  use Ecto.Migration

  def change do
    create table(:document_permissions) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :person_id, references(:people, on_delete: :delete_all)
      add :team_id, references(:teams, on_delete: :delete_all)
      add :access_rights, {:array, :string}, null: false, default: ["read"]

      timestamps(type: :utc_datetime)
    end

    create index(:document_permissions, [:document_id])

    execute(
      """
      ALTER TABLE document_permissions
        ADD CONSTRAINT check_person_or_team_present
        CHECK (person_id IS NOT NULL OR team_id IS NOT NULL)
      """,
      """
      ALTER TABLE document_permissions
        DROP CONSTRAINT check_person_or_team_present
      """
    )

    execute(
      """
      CREATE UNIQUE INDEX uix_doc_perm_person ON document_permissions (document_id, person_id)
        WHERE person_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS uix_doc_perm_person"
    )

    execute(
      """
      CREATE UNIQUE INDEX uix_doc_perm_team ON document_permissions (document_id, team_id)
        WHERE team_id IS NOT NULL
      """,
      "DROP INDEX IF EXISTS uix_doc_perm_team"
    )
  end
end
