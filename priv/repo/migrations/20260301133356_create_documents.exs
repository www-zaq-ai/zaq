defmodule Zaq.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents) do
      add :title, :string
      add :source, :string, null: false
      add :content, :text, null: false
      add :content_type, :string, default: "markdown", null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:documents, [:source])
  end
end
