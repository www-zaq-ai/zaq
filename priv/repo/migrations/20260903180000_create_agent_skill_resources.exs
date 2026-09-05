defmodule Zaq.Repo.Migrations.CreateAgentSkillResources do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:agent_skill_resources) do
      add :skill_id, references(:agent_skills, on_delete: :delete_all), null: false
      add :provider_resource_id, :string, null: false
      add :name, :string, null: false
      add :resource_type, :string, null: false, default: "reference"
      add :size, :bigint, null: false, default: 0
      add :mime_type, :string
      add :modified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:agent_skill_resources, [:skill_id, :provider_resource_id])
    create_if_not_exists unique_index(:agent_skill_resources, [:skill_id, :name])

    create constraint(:agent_skill_resources, :resource_type_valid,
             check: "resource_type IN ('reference', 'asset', 'script')"
           )
  end
end
