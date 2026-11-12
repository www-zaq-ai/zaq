defmodule Zaq.Repo.Migrations.AlignTypedLabelAssignments do
  use Ecto.Migration

  def up do
    # Development label assignments are discarded; definitions retain their names.
    alter table(:labels) do
      add :value_type, :string, null: false, default: "boolean"
      add :value_config, :map, null: false, default: %{}
      add :resources, {:array, :string}, null: false, default: ["document", "chunk"]
      add :assignment_type, :string, null: false, default: "manual"
      add :threshold, :integer, null: false, default: 80
    end

    create constraint(:labels, :label_value_type,
             check: "value_type IN ('boolean', 'scale', 'options')"
           )

    create constraint(:labels, :label_assignment_type,
             check: "assignment_type IN ('manual', 'automatic')"
           )

    create constraint(:labels, :label_threshold, check: "threshold BETWEEN 0 AND 100")

    create constraint(:labels, :label_resources,
             check:
               "cardinality(resources) BETWEEN 1 AND 2 AND resources <@ ARRAY['document','chunk']::varchar[]"
           )

    create table(:label_assignments) do
      add :label_id, references(:labels, on_delete: :restrict), null: false
      add :resource_type, :string, null: false
      add :resource_id, :text, null: false
      add :value, :map
      add :state, :string, null: false
      add :origin, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:label_assignments, [:resource_type, :resource_id, :label_id])
    create index(:label_assignments, [:label_id])

    create constraint(:label_assignments, :label_resource_type,
             check: "resource_type IN ('document', 'chunk', 'folder')"
           )

    create constraint(:label_assignments, :label_resource_identity,
             check:
               "(resource_type IN ('document', 'chunk') AND resource_id ~ '^[1-9][0-9]*$') OR (resource_type = 'folder' AND length(resource_id) > 0)"
           )

    create constraint(:label_assignments, :label_assignment_state,
             check: "state IN ('assigned', 'pending', 'excluded')"
           )

    create constraint(:label_assignments, :label_assignment_origin,
             check: "origin IN ('manual', 'automatic')"
           )

    create constraint(:label_assignments, :label_assignment_value,
             check:
               "(state = 'assigned' AND value IS NOT NULL AND jsonb_typeof(value) = 'object' AND value ? 'value' AND value - 'value' = '{}'::jsonb AND jsonb_typeof(value->'value') IN ('boolean', 'number', 'string')) OR (state <> 'assigned' AND value IS NULL)"
           )

    create constraint(:label_assignments, :pending_automatic_origin,
             check: "state <> 'pending' OR origin = 'automatic'"
           )

    execute("""
    ALTER TABLE label_assignments
      ADD COLUMN document_id bigint GENERATED ALWAYS AS
        (CASE WHEN resource_type = 'document' THEN resource_id::bigint END) STORED,
      ADD COLUMN chunk_id bigint GENERATED ALWAYS AS
        (CASE WHEN resource_type = 'chunk' THEN resource_id::bigint END) STORED,
      ADD CONSTRAINT label_assignments_document_id_fkey
        FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE;
    """)

    execute("""
    DO $$ BEGIN
      IF to_regclass('chunks') IS NOT NULL THEN
        ALTER TABLE label_assignments ADD CONSTRAINT label_assignments_chunk_id_fkey
          FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE;
      ELSE
        ALTER TABLE label_assignments ADD CONSTRAINT chunk_resource_available
          CHECK (resource_type <> 'chunk');
      END IF;
    END $$;
    """)

    create index(:label_assignments, [:document_id], where: "document_id IS NOT NULL")
    create index(:label_assignments, [:chunk_id], where: "chunk_id IS NOT NULL")

    execute("""
    UPDATE labels l SET resources = coalesce(
      (SELECT array_agg(t.resource_type ORDER BY t.resource_type)
       FROM label_targets t WHERE t.label_id = l.id), resources);
    """)

    drop table(:document_label_assignments)
    drop table(:chunk_label_assignments)
    drop table(:label_targets)
  end

  def down do
    # Rollback restores empty assignment tables; it does not convert typed values.
    drop table(:label_assignments)

    for name <- [:label_value_type, :label_assignment_type, :label_threshold, :label_resources],
        do: drop(constraint(:labels, name))

    create table(:label_targets) do
      add :label_id, references(:labels, on_delete: :delete_all), null: false
      add :resource_type, :string, null: false
      add :automatic, :boolean, null: false, default: false
    end

    create unique_index(:label_targets, [:label_id, :resource_type])

    create constraint(:label_targets, :label_target_type,
             check: "resource_type IN ('document', 'chunk')"
           )

    execute("""
    INSERT INTO label_targets (label_id, resource_type, automatic)
    SELECT l.id, resource_type, false FROM labels l CROSS JOIN unnest(l.resources) AS resource_type;
    """)

    for {table, resource, key} <- [
          {:document_label_assignments, :documents, :document_id},
          {:chunk_label_assignments, :chunks, :chunk_id}
        ] do
      create table(table) do
        add :label_id, references(:labels, on_delete: :restrict), null: false

        if resource == :documents,
          do: add(key, references(resource, on_delete: :delete_all), null: false),
          else: add(key, :bigint, null: false)

        add :selected, :boolean, null: false
        add :origin, :string, null: false, default: "manual"
        add :lock_version, :integer, null: false, default: 1
        add :value, :text
        timestamps(type: :utc_datetime_usec)
      end

      create unique_index(table, [key, :label_id])
      create index(table, [:label_id])
      create constraint(table, :manual_label_origin, check: "origin = 'manual'")
    end

    execute("""
    DO $$ BEGIN
      IF to_regclass('chunks') IS NOT NULL THEN
        ALTER TABLE chunk_label_assignments ADD CONSTRAINT chunk_label_assignments_chunk_id_fkey
          FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE;
      ELSE
        ALTER TABLE chunk_label_assignments ADD CONSTRAINT chunk_resource_available CHECK (false);
      END IF;
    END $$;
    """)

    alter table(:labels) do
      remove :value_type
      remove :value_config
      remove :resources
      remove :assignment_type
      remove :threshold
    end
  end
end
