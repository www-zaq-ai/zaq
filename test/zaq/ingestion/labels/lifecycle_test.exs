unless Code.ensure_loaded?(Zaq.Repo.Migrations.CreateResourceLabels) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261103081329_create_resource_labels.exs",
    __DIR__
  )
end

defmodule Zaq.Ingestion.Labels.LifecycleTest do
  # Embedding setup/reset performs table DDL and must not race async document writers.
  use Zaq.DataCase, async: false
  alias Zaq.Ingestion.{Chunk, Document, Labels}
  alias Zaq.Ingestion.Labels.Assignment
  alias Zaq.Ingestion.Labels.Label
  alias Zaq.Repo.Migrations.CreateResourceLabels

  @migration_version 20_261_103_081_329
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

  test "label schema rollback and recreation preserve unrelated resources", ctx do
    {:ok, _} =
      Document.upsert(%{source: ctx.document.source, content: "Retained document content"})

    {:ok, _} = Zaq.Permissions.grant_public(ctx.document)
    document = Repo.get!(Document, ctx.document.id)

    permissions =
      Repo.query!("SELECT to_jsonb(row) FROM resource_permissions row ORDER BY id").rows

    chunk = Repo.get!(Chunk, ctx.chunk.id)

    assert :ok = migrate(:down)

    assert %{rows: [[nil, nil]]} =
             Repo.query!("SELECT to_regclass('labels'), to_regclass('label_assignments')")

    assert :ok = migrate(:up)
    assert :already_up = migrate(:up)
    assert Repo.aggregate(Assignment, :count) == 0
    assert Repo.aggregate(Label, :count) == 0

    {:ok, label} =
      Labels.save_definition(
        %{name: "Fresh Boolean", resources: ["document", "chunk"]},
        ctx.actor
      )

    assert %{value_type: "boolean", value_config: %{}, assignment_type: "manual"} = label
    assert MapSet.new(label.resources) == MapSet.new(["document", "chunk"])
    assert Label.changeset(label, %{}).valid?
    assert Repo.get!(Chunk, ctx.chunk.id) == chunk

    assert Repo.get!(Document, ctx.document.id) == document

    assert Repo.query!("SELECT to_jsonb(row) FROM resource_permissions row ORDER BY id").rows ==
             permissions

    assert %{rows: [[nil, nil, nil]]} =
             Repo.query!(
               "SELECT to_regclass('document_label_assignments'), to_regclass('chunk_label_assignments'), to_regclass('label_targets')"
             )

    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "document", id: document.id},
               [%{label_id: label.id, operation: "add", value: false, expected_version: 0}],
               ctx.actor
             )

    assert :ok = migrate(:down)

    assert %{rows: [[nil, nil]]} =
             Repo.query!("SELECT to_regclass('labels'), to_regclass('label_assignments')")

    assert :ok = migrate(:up)
    assert Repo.aggregate(Assignment, :count) == 0
  end

  test "fresh labeling schemas migrate without an embedding table", ctx do
    assert :ok = migrate(:down)
    assert :ok = Chunk.drop_table()
    assert :ok = migrate(:up)
    assert Repo.aggregate(Assignment, :count) == 0
    assert Repo.aggregate(Label, :count) == 0

    {:ok, label} =
      Labels.save_definition(%{name: "Fresh Boolean", resources: ["document"]}, ctx.actor)

    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "document", id: ctx.document.id},
               [%{label_id: label.id, operation: "add", value: false, expected_version: 0}],
               ctx.actor
             )

    assert Repo.get_by!(Assignment, label_id: label.id).value == false
    refute Chunk.table_exists?()
  end

  defp migrate(direction),
    do:
      apply(Ecto.Migrator, direction, [
        Repo,
        @migration_version,
        CreateResourceLabels,
        @migration_opts
      ])
end
