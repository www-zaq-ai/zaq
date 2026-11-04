defmodule Zaq.Repo.Migrations.CreateResourceLabels do
  use Ecto.Migration

  def change do
    create table(:labels) do
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :normalized_name, :string, null: false
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:labels, [:normalized_name])

    create table(:label_targets) do
      add :label_id, references(:labels, on_delete: :delete_all), null: false
      add :resource_type, :string, null: false
      add :automatic, :boolean, null: false, default: false
    end

    create unique_index(:label_targets, [:label_id, :resource_type])

    create constraint(:label_targets, :label_target_type,
             check: "resource_type IN ('document', 'chunk')"
           )

    for {table, resource, foreign_key} <- [
          {:document_label_assignments, :documents, :document_id},
          {:chunk_label_assignments, :chunks, :chunk_id}
        ] do
      create table(table) do
        add :label_id, references(:labels, on_delete: :restrict), null: false

        if resource == :chunks do
          add foreign_key, :bigint, null: false
        else
          add foreign_key, references(resource, on_delete: :delete_all), null: false
        end

        add :selected, :boolean, null: false
        add :origin, :string, null: false, default: "manual"
        add :lock_version, :integer, null: false, default: 1
        timestamps(type: :utc_datetime_usec)
        add :value, :text
      end

      create unique_index(table, [foreign_key, :label_id])
      create index(table, [:label_id])
      create constraint(table, :manual_label_origin, check: "origin = 'manual'")
    end

    # The embedding model owns the dynamic chunks table. Without it, forbid all
    # chunk assignments; create_table/1 swaps this guard for a real foreign key.
    execute(
      """
      DO $$ BEGIN
        IF to_regclass('chunks') IS NOT NULL THEN
          ALTER TABLE chunk_label_assignments
            ADD CONSTRAINT chunk_label_assignments_chunk_id_fkey
            FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE;
        ELSE
          ALTER TABLE chunk_label_assignments
            ADD CONSTRAINT chunk_resource_available CHECK (false);
        END IF;
      END $$
      """,
      "SELECT 1"
    )
  end
end
