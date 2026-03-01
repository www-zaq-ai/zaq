defmodule Zaq.Repo.Migrations.CreatePromptTemplates do
  use Ecto.Migration

  def change do
    create table(:prompt_templates) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :body, :text, null: false
      add :description, :text
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:prompt_templates, [:slug])
  end
end
