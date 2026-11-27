defmodule Zaq.Repo.Migrations.CreateChunkRefreshes do
  use Ecto.Migration

  def change do
    create table(:chunk_refreshes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :document_id, references(:documents, on_delete: :nilify_all)
      add :user_id, :bigint, null: false
      add :source, :text, null: false
      add :embedding_model, :text, null: false
      add :embedding_dimension, :integer, null: false
    end

    create index(:chunk_refreshes, [:document_id])

    alter table(:documents) do
      add :chunk_refresh_id, :uuid
      add :chunk_refresh_started_at, :utc_datetime_usec
    end
  end
end
