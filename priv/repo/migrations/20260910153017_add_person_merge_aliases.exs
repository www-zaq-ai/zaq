defmodule Zaq.Repo.Migrations.AddPersonMergeAliases do
  use Ecto.Migration

  def change do
    alter table(:people) do
      add :merged_person_ids, {:array, :bigint}, default: [], null: false
      add :merge_history, :map, default: fragment("'[]'::jsonb"), null: false
    end

    create index(:people, [:merged_person_ids], using: :gin)

    create constraint(:people, :people_aliases_exclude_self,
             check: "NOT (id = ANY(merged_person_ids))"
           )

    create constraint(:people, :people_merge_history_list,
             check: "jsonb_typeof(merge_history) = 'array'"
           )
  end
end
