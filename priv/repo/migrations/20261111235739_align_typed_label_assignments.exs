defmodule Zaq.Repo.Migrations.AlignTypedLabelAssignments do
  use Ecto.Migration

  def up do
    # Each saved legacy text becomes an immutable option identity. Nil is a
    # separate choice; no text is interpreted as a Boolean or a numeric scale.
    execute("""
    LOCK TABLE labels, label_targets, document_label_assignments, chunk_label_assignments
      IN ACCESS EXCLUSIVE MODE;
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM labels l WHERE NOT EXISTS (SELECT 1 FROM label_targets t WHERE t.label_id = l.id))
        OR EXISTS (SELECT 1 FROM label_targets WHERE automatic) THEN
        RAISE EXCEPTION 'Legacy labels require valid manual document/chunk targets before typed migration';
      END IF;
      IF EXISTS (
        SELECT 1 FROM (
          SELECT value FROM document_label_assignments WHERE selected
          UNION ALL SELECT value FROM chunk_label_assignments WHERE selected
        ) a WHERE value IS NOT NULL AND (length(value) > 200 OR btrim(value) = '')
      ) THEN
        RAISE EXCEPTION 'Legacy label values contain blank or overlong raw text; repair explicitly before typed migration';
      END IF;
    END $$;
    """)

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
    WITH legacy_values AS (
      SELECT label_id, value FROM document_label_assignments WHERE selected
      UNION SELECT label_id, value FROM chunk_label_assignments WHERE selected
    ), configs AS (#{legacy_configs_sql()})
    UPDATE labels l SET
      value_type = 'options',
      value_config = coalesce((SELECT config FROM configs c WHERE c.label_id = l.id), #{unspecified_config_sql()}),
      resources = (SELECT array_agg(t.resource_type ORDER BY t.resource_type) FROM label_targets t WHERE t.label_id = l.id);
    """)

    for {table, type, key} <- legacy_assignment_tables() do
      execute("""
      INSERT INTO label_assignments
        (label_id, resource_type, resource_id, value, state, origin, metadata, lock_version, inserted_at, updated_at)
      SELECT label_id, '#{type}', #{key}::text,
        CASE WHEN selected THEN jsonb_build_object('value', #{legacy_option_id_sql("value")}) END,
        CASE WHEN selected THEN 'assigned' ELSE 'excluded' END, origin,
        jsonb_build_object('legacy', jsonb_build_object(
          'table', '#{table}', 'id', id, 'label_id', label_id, 'resource_id', #{key},
          'value', value, 'selected', selected, 'origin', origin, 'lock_version', lock_version,
          'inserted_at', inserted_at, 'updated_at', updated_at)),
        lock_version, inserted_at, updated_at
      FROM #{table};
      """)
    end

    drop table(:document_label_assignments)
    drop table(:chunk_label_assignments)
    drop table(:label_targets)
  end

  def down do
    # Only unchanged migrated decisions can be represented in the previous
    # schema. Refuse rollback before DDL when newer typed state would be lost.
    execute("LOCK TABLE labels, label_assignments IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM label_assignments a WHERE NOT coalesce(
        a.metadata - 'legacy' = '{}'::jsonb AND
        a.metadata->'legacy'->>'table' = CASE a.resource_type WHEN 'document' THEN 'document_label_assignments' WHEN 'chunk' THEN 'chunk_label_assignments' END AND
        a.metadata->'legacy'->>'id' ~ '^[1-9][0-9]*$' AND
        a.metadata->'legacy'->>'label_id' = a.label_id::text AND
        a.metadata->'legacy'->>'resource_id' = a.resource_id AND
        a.metadata->'legacy'->>'origin' = a.origin AND a.origin = 'manual' AND
        a.metadata->'legacy'->>'lock_version' = a.lock_version::text AND
        a.metadata->'legacy'->'inserted_at' = to_jsonb(a.inserted_at) AND
        a.metadata->'legacy'->'updated_at' = to_jsonb(a.updated_at) AND
        a.state = CASE WHEN (a.metadata->'legacy'->>'selected')::boolean THEN 'assigned' ELSE 'excluded' END AND
        a.value IS NOT DISTINCT FROM CASE WHEN a.state = 'assigned' THEN
          jsonb_build_object('value', #{legacy_option_id_sql("a.metadata->'legacy'->>'value'")}) END,
        false)) THEN
        RAISE EXCEPTION 'Typed label rollback would lose new or edited assignments; export or explicitly migrate them first';
      END IF;
    END $$;
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (
        WITH legacy_values AS (
          SELECT DISTINCT label_id, metadata->'legacy'->>'value' AS value
          FROM label_assignments WHERE (metadata->'legacy'->>'selected')::boolean
        ), configs AS (#{legacy_configs_sql()})
        SELECT 1 FROM labels l
        WHERE l.value_type <> 'options' OR l.assignment_type <> 'manual' OR l.threshold <> 80
          OR l.value_config IS DISTINCT FROM coalesce((SELECT config FROM configs c WHERE c.label_id = l.id), #{unspecified_config_sql()})
      ) THEN
        RAISE EXCEPTION 'Typed label rollback would lose new definition configuration; export or explicitly migrate it first';
      END IF;
    END $$;
    """)

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

    for {table, type, key} <- legacy_assignment_tables() do
      execute("""
      INSERT INTO #{table} (id, label_id, #{key}, selected, origin, lock_version, value, inserted_at, updated_at)
      SELECT (metadata->'legacy'->>'id')::bigint, label_id, resource_id::bigint,
        (metadata->'legacy'->>'selected')::boolean, origin, lock_version,
        metadata->'legacy'->>'value', inserted_at, updated_at
      FROM label_assignments WHERE resource_type = '#{type}';
      """)

      execute("""
      SELECT setval(pg_get_serial_sequence('#{table}', 'id'), greatest(coalesce(max(id), 0), 1), max(id) IS NOT NULL) FROM #{table};
      """)
    end

    drop table(:label_assignments)

    alter table(:labels) do
      remove :value_type
      remove :value_config
      remove :resources
      remove :assignment_type
      remove :threshold
    end
  end

  defp legacy_assignment_tables,
    do: [
      {:document_label_assignments, "document", :document_id},
      {:chunk_label_assignments, "chunk", :chunk_id}
    ]

  defp legacy_option_id_sql(value),
    do:
      "CASE WHEN #{value} IS NULL THEN 'legacy-unspecified' ELSE 'legacy-value-' || encode(sha256(convert_to(#{value}, 'UTF8')), 'hex') END"

  defp unspecified_config_sql,
    do: ~s('{"options":[{"id":"legacy-unspecified","label":"Unspecified"}]}'::jsonb)

  defp legacy_configs_sql do
    """
    SELECT v.label_id, jsonb_build_object('options', jsonb_agg(jsonb_build_object(
      'id', #{legacy_option_id_sql("v.value")},
      'label', CASE WHEN v.value IS NULL AND EXISTS (
        SELECT 1 FROM legacy_values other WHERE other.label_id = v.label_id AND other.value = 'Unspecified'
      ) THEN 'Unspecified (previously blank)' ELSE coalesce(v.value, 'Unspecified') END
    ) ORDER BY v.value NULLS FIRST)) AS config
    FROM legacy_values v GROUP BY v.label_id
    """
  end
end
