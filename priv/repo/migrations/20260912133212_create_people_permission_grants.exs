defmodule Zaq.Repo.Migrations.CreatePeoplePermissionGrants do
  use Ecto.Migration

  def change do
    create table(:people_permission_grants) do
      add :scope_type, :string, null: false
      add :scope_id, references(:teams, on_delete: :delete_all), null: true
      add :permission, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create constraint(:people_permission_grants, :people_permission_grants_scope_type_check,
             check: "scope_type IN ('all_people', 'team')"
           )

    create constraint(:people_permission_grants, :people_permission_grants_scope_id_check,
             check:
               "(scope_type = 'all_people' AND scope_id IS NULL) OR (scope_type = 'team' AND scope_id IS NOT NULL)"
           )

    create constraint(:people_permission_grants, :people_permission_grants_permission_check,
             check:
               "permission IN ('access_profile', 'access_message_history', 'share_conversations')"
           )

    create unique_index(:people_permission_grants, [:permission],
             where: "scope_type = 'all_people'",
             name: :people_permission_grants_all_people_unique
           )

    create unique_index(:people_permission_grants, [:scope_id, :permission],
             where: "scope_type = 'team'",
             name: :people_permission_grants_team_unique
           )
  end
end
