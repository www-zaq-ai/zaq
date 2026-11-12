unless Code.ensure_loaded?(Zaq.Repo.Migrations.AlignTypedLabelAssignments) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261111235739_align_typed_label_assignments.exs",
    __DIR__
  )
end

defmodule Zaq.Ingestion.Labels.LifecycleTest do
  # Embedding setup/reset performs table DDL and must not race async document writers.
  use Zaq.DataCase, async: false
  alias Zaq.Ingestion.{Chunk, Document, Labels}
  alias Zaq.Ingestion.Labels.Assignment
  alias Zaq.Ingestion.Labels.Label
  alias Zaq.Repo.Migrations.AlignTypedLabelAssignments

  @migration_version 20_261_111_235_739
  @migration_opts [log: false, migration_lock: false, skip_table_creation: true]

  setup do
    Zaq.SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})
    user = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: user.id}
    {:ok, document} = Document.create(%{source: "label-lifecycle"})
    # Equal numeric IDs prove resource types have independent assignment identity.
    chunk =
      Repo.insert!(%Chunk{
        id: document.id,
        document_id: document.id,
        content: "Access control",
        chunk_index: 0
      })

    {:ok, label} =
      Labels.save_definition(%{name: "Security", resources: ["document", "chunk"]}, actor)

    for {type, id} <- [{"document", document.id}, {"chunk", chunk.id}] do
      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: type, id: id},
                 [%{label_id: label.id, operation: "add", value: true, expected_version: 0}],
                 actor
               )
    end

    %{actor: actor, document: document, chunk: chunk, label: label}
  end

  test "chunk values are independent of document values and available as suggestions", ctx do
    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "chunk", id: ctx.chunk.id},
               [%{label_id: ctx.label.id, operation: "add", expected_version: 1, value: false}],
               ctx.actor
             )

    assert {:ok, %{labels: [%{value: false}]}} =
             Labels.resource_editor(%{type: "chunk", id: ctx.chunk.id}, ctx.actor)

    assert {:ok, %{labels: [%{value: true}]}} =
             Labels.resource_editor(%{type: "document", id: ctx.document.id}, ctx.actor)

    assert {:ok, [false]} =
             Labels.value_suggestions(
               %{type: "document", id: ctx.document.id},
               ctx.label.id,
               "false",
               ctx.actor
             )
  end

  test "deleting a label clears both assignment types and preserves resources", ctx do
    assert {:ok, preview} = Labels.deletion_preview(ctx.label.id, ctx.actor)
    assert preview.usage == %{documents: 1, chunks: 1}

    assert {:ok, _} =
             Labels.delete_definition(
               %{
                 id: preview.id,
                 expected_version: preview.expected_version,
                 expected_usage: preview.usage
               },
               ctx.actor
             )

    assert Repo.get(Document, ctx.document.id)
    assert Repo.get(Chunk, ctx.chunk.id)
    refute Repo.get_by(Assignment, label_id: ctx.label.id)
  end

  test "document assignments survive upsert while chunk deletion cascades", %{
    document: document,
    chunk: chunk
  } do
    assert {:ok, %{id: id}} = Document.upsert(%{source: document.source, content: "new content"})
    assert id == document.id
    assert Repo.get_by!(Assignment, document_id: id).state == :assigned
    Repo.delete!(chunk)
    refute Repo.get_by(Assignment, chunk_id: chunk.id)
    assert Repo.get_by!(Assignment, document_id: id).state == :assigned
  end

  test "embedding reset removes old assignments and restores the foreign key", %{
    document: document,
    chunk: chunk,
    label: label,
    actor: actor
  } do
    assert :ok = Chunk.reset_table(384)
    refute Repo.get_by(Assignment, chunk_id: chunk.id)
    assert Repo.get_by!(Assignment, document_id: document.id).state == :assigned
    assert {:error, :not_found} = Labels.resource_editor(%{type: "chunk", id: chunk.id}, actor)

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'label_assignments'::regclass AND conname = 'label_assignments_chunk_id_fkey')"
             )

    changeset =
      Assignment.decision_changeset(
        %Assignment{resource_type: "chunk", resource_id: to_string(chunk.id), label_id: label.id},
        label,
        "add",
        true
      )

    assert {:error, changeset} = Repo.insert(changeset)
    assert errors_on(changeset).resource_id == ["does not exist"]
  end

  test "chunk reset never reuses a stale editor's resource identity", ctx do
    {:ok, original} =
      Chunk.create(%{document_id: ctx.document.id, content: "Original", chunk_index: 1})

    resource = %{type: "chunk", id: original.id}

    assert {:ok, %{labels: [%{expected_version: 0}]}} =
             Labels.resource_editor(resource, ctx.actor)

    assert :ok = Chunk.reset_table(384)

    {:ok, replacement} =
      Chunk.create(%{document_id: ctx.document.id, content: "Replacement", chunk_index: 0})

    assert replacement.id > original.id

    assert {:error, :not_found} =
             Labels.edit_resource(
               resource,
               [
                 %{label_id: ctx.label.id, operation: "add", value: true, expected_version: 0}
               ],
               ctx.actor
             )

    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "chunk", id: replacement.id},
               [
                 %{label_id: ctx.label.id, operation: "add", value: false, expected_version: 0}
               ],
               ctx.actor
             )

    assert Repo.get_by!(Assignment,
             resource_type: "document",
             resource_id: to_string(ctx.document.id)
           ).state == :assigned

    assert Repo.get_by!(Assignment,
             resource_type: "chunk",
             resource_id: to_string(replacement.id)
           ).value == false

    Repo.delete!(replacement)
    refute Repo.get_by(Assignment, resource_type: "chunk", resource_id: to_string(replacement.id))
    Repo.delete!(ctx.document)

    refute Repo.get_by(Assignment,
             resource_type: "document",
             resource_id: to_string(ctx.document.id)
           )
  end

  test "chunk creation succeeds before label assignment tables exist" do
    # DDL is rolled back with this test's SQL Sandbox transaction.
    Repo.query!("DROP TABLE label_assignments")
    assert :ok = Chunk.drop_table()
    refute Chunk.table_exists?()

    assert :ok = Chunk.create_table(384)
    assert Chunk.table_exists?()
    assert :ok = Chunk.create_table(384)
    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass('label_assignments')")
  end

  test "unavailable chunks reject assignments until recreation", %{chunk: chunk, actor: actor} do
    assert :ok = Chunk.drop_table()
    assert :ok = Chunk.drop_table()
    assert {:error, :not_found} = Labels.resource_editor(%{type: "chunk", id: chunk.id}, actor)

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'label_assignments'::regclass AND conname = 'chunk_resource_available')"
             )

    assert :ok = Chunk.create_table(384)

    assert %{rows: [[false]]} =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'label_assignments'::regclass AND conname = 'chunk_resource_available')"
             )
  end

  test "legacy labels upgrade and roll back losslessly with stable options", ctx do
    {:ok, preview} = Labels.deletion_preview(ctx.label.id, ctx.actor)

    {:ok, _} =
      Labels.delete_definition(
        %{
          id: ctx.label.id,
          expected_version: preview.expected_version,
          expected_usage: preview.usage
        },
        ctx.actor
      )

    assert :ok = migrate(:down)

    legacy_ids = insert_legacy_labels()
    [location, note, unused] = legacy_ids
    {:ok, second} = Document.create(%{source: "legacy-second"})
    {:ok, third} = Document.create(%{source: "legacy-third"})

    entries = [
      {"document", ctx.document.id, location, true, "Paris"},
      {"document", second.id, location, true, nil},
      {"document", third.id, location, true, "Unspecified"},
      {"document", ctx.document.id, note, true, "Café"},
      {"document", second.id, note, false, "retained exclusion text"},
      {"chunk", ctx.chunk.id, location, true, "Paris"},
      {"chunk", ctx.chunk.id, note, true, "東京"}
    ]

    Enum.each(entries, &insert_legacy_assignment/1)
    legacy = legacy_snapshot()

    assert :ok = migrate(:up)
    assert :already_up = migrate(:up)
    assert Repo.aggregate(Assignment, :count) == 7
    labels = Repo.all(from l in Label, order_by: l.id)
    assert Enum.all?(labels, &Label.changeset(&1, %{}).valid?)
    assert Enum.all?(labels, &(&1.value_type == "options" and &1.lock_version == 4))

    assert Repo.get!(Label, unused).value_config == %{
             "options" => [%{"id" => "legacy-unspecified", "label" => "Unspecified"}]
           }

    options = Repo.get!(Label, location).value_config["options"]
    assert %{"id" => "legacy-unspecified", "label" => "Unspecified (previously blank)"} in options
    assert %{"id" => legacy_option_id("Unspecified"), "label" => "Unspecified"} in options
    assert %{"id" => legacy_option_id("Paris"), "label" => "Paris"} in options

    for assignment <- Repo.all(Assignment) do
      original = assignment.metadata["legacy"]
      assert assignment.lock_version == original["lock_version"]
      assert assignment.label_id == original["label_id"]
      assert assignment.resource_id == to_string(original["resource_id"])
      assert assignment.origin == :manual

      assert NaiveDateTime.to_iso8601(DateTime.to_naive(assignment.inserted_at)) ==
               original["inserted_at"]

      assert NaiveDateTime.to_iso8601(DateTime.to_naive(assignment.updated_at)) ==
               original["updated_at"]

      if original["selected"],
        do: assert(assignment.value == legacy_option_id(original["value"])),
        else: assert(assignment.state == :excluded and assignment.value == nil)
    end

    configs = Map.new(labels, &{&1.id, &1.value_config})
    assert :ok = migrate(:down)
    assert legacy_snapshot() == legacy
    assert :ok = migrate(:up)
    assert Map.new(Repo.all(Label), &{&1.id, &1.value_config}) == configs

    original =
      Repo.get_by!(Assignment,
        resource_type: "document",
        resource_id: to_string(ctx.document.id),
        label_id: location
      )

    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "document", id: ctx.document.id},
               [
                 %{
                   label_id: location,
                   operation: "add",
                   value: legacy_option_id("Paris"),
                   expected_version: original.lock_version
                 }
               ],
               ctx.actor
             )

    assert_raise Postgrex.Error, ~r/rollback would lose new or edited assignments/, fn ->
      migrate(:down)
    end
  end

  defp migrate(direction),
    do:
      apply(Ecto.Migrator, direction, [
        Repo,
        @migration_version,
        AlignTypedLabelAssignments,
        @migration_opts
      ])

  defp insert_legacy_labels do
    for name <- ["Legacy location", "Legacy note", "Legacy unused"] do
      %{rows: [[id]]} =
        Repo.query!(
          "INSERT INTO labels (name, normalized_name, description, lock_version, inserted_at, updated_at) VALUES ($1::varchar, lower($1::varchar), 'Retained description', 4, '2020-01-02 03:04:05.123456', '2021-02-03 04:05:06.654321') RETURNING id",
          [name]
        )

      Repo.query!(
        "INSERT INTO label_targets (label_id, resource_type) VALUES ($1, 'document'), ($1, 'chunk')",
        [id]
      )

      id
    end
  end

  defp insert_legacy_assignment({type, resource_id, label_id, selected, value}) do
    {table, key} =
      if type == "document",
        do: {"document_label_assignments", "document_id"},
        else: {"chunk_label_assignments", "chunk_id"}

    Repo.query!(
      "INSERT INTO #{table} (label_id, #{key}, selected, origin, lock_version, value, inserted_at, updated_at) VALUES ($1, $2, $3, 'manual', 5, $4, '2020-01-02 03:04:05.123456', '2021-02-03 04:05:06.654321')",
      [label_id, resource_id, selected, value]
    )
  end

  defp legacy_snapshot do
    for table <- ["labels", "document_label_assignments", "chunk_label_assignments"],
        into: %{},
        do: {table, Repo.query!("SELECT to_jsonb(row) FROM #{table} row ORDER BY id").rows}
  end

  defp legacy_option_id(nil), do: "legacy-unspecified"

  defp legacy_option_id(value),
    do: "legacy-value-" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
