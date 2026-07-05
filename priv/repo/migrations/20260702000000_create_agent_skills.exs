defmodule Zaq.Repo.Migrations.CreateAgentSkills do
  use Ecto.Migration

  def change do
    create table(:agent_skills) do
      add :name, :string, null: false
      add :description, :text
      add :body, :text, null: false
      add :tool_keys, {:array, :string}, null: false, default: []
      add :tags, {:array, :string}, null: false, default: []
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_skills, [:name])
    create index(:agent_skills, [:active])
    create index(:agent_skills, [:tags], using: "GIN")
  end
end
