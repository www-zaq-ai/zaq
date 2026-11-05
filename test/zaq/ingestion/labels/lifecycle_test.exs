defmodule Zaq.Ingestion.Labels.LifecycleTest do
  # Embedding setup/reset performs table DDL and must not race async document writers.
  use Zaq.DataCase, async: false
  alias Zaq.Ingestion.{Chunk, Document, Labels}
  alias Zaq.Ingestion.Labels.{ChunkAssignment, DocumentAssignment}

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
      Labels.save_definition(%{name: "Security", targets: ["document", "chunk"]}, actor)

    for {type, id} <- [{"document", document.id}, {"chunk", chunk.id}] do
      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: type, id: id},
                 [%{label_id: label.id, operation: "add", expected_version: 0}],
                 actor
               )
    end

    %{actor: actor, document: document, chunk: chunk, label: label}
  end

  test "chunk values are independent of document values and available as suggestions", ctx do
    assert {:ok, _} =
             Labels.edit_resource(
               %{type: "chunk", id: ctx.chunk.id},
               [%{label_id: ctx.label.id, operation: "add", expected_version: 1, value: "Paris"}],
               ctx.actor
             )

    assert {:ok, %{labels: [%{value: "Paris"}]}} =
             Labels.resource_editor(%{type: "chunk", id: ctx.chunk.id}, ctx.actor)

    assert {:ok, %{labels: [%{value: nil}]}} =
             Labels.resource_editor(%{type: "document", id: ctx.document.id}, ctx.actor)

    assert {:ok, ["Paris"]} =
             Labels.value_suggestions(
               %{type: "document", id: ctx.document.id},
               ctx.label.id,
               "",
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
    refute Repo.get_by(DocumentAssignment, label_id: ctx.label.id)
    refute Repo.get_by(ChunkAssignment, label_id: ctx.label.id)
  end

  test "document assignments survive upsert while chunk deletion cascades", %{
    document: document,
    chunk: chunk
  } do
    assert {:ok, %{id: id}} = Document.upsert(%{source: document.source, content: "new content"})
    assert id == document.id
    assert Repo.get_by!(DocumentAssignment, document_id: id).selected
    Repo.delete!(chunk)
    refute Repo.get_by(ChunkAssignment, chunk_id: chunk.id)
    assert Repo.get_by!(DocumentAssignment, document_id: id).selected
  end

  test "embedding reset removes old assignments and restores the foreign key", %{
    document: document,
    chunk: chunk,
    label: label,
    actor: actor
  } do
    assert :ok = Chunk.reset_table(384)
    refute Repo.get_by(ChunkAssignment, chunk_id: chunk.id)
    assert Repo.get_by!(DocumentAssignment, document_id: document.id).selected
    assert {:error, :not_found} = Labels.resource_editor(%{type: "chunk", id: chunk.id}, actor)

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'chunk_label_assignments'::regclass AND conname = 'chunk_label_assignments_chunk_id_fkey')"
             )

    changeset =
      ChunkAssignment.decision_changeset(
        %ChunkAssignment{chunk_id: chunk.id, label_id: label.id},
        true
      )

    assert {:error, changeset} = Repo.insert(changeset)
    assert errors_on(changeset).chunk_id == ["does not exist"]
  end

  test "chunk creation succeeds before label assignment tables exist" do
    # DDL is rolled back with this test's SQL Sandbox transaction.
    Repo.query!("DROP TABLE chunk_label_assignments")
    assert :ok = Chunk.drop_table()
    refute Chunk.table_exists?()

    assert :ok = Chunk.create_table(384)
    assert Chunk.table_exists?()
    assert :ok = Chunk.create_table(384)
    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass('chunk_label_assignments')")
  end

  test "unavailable chunks reject assignments until recreation", %{chunk: chunk, actor: actor} do
    assert :ok = Chunk.drop_table()
    assert :ok = Chunk.drop_table()
    assert {:error, :not_found} = Labels.resource_editor(%{type: "chunk", id: chunk.id}, actor)

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'chunk_label_assignments'::regclass AND conname = 'chunk_resource_available')"
             )

    assert :ok = Chunk.create_table(384)

    assert %{rows: [[false]]} =
             Repo.query!(
               "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'chunk_label_assignments'::regclass AND conname = 'chunk_resource_available')"
             )
  end
end
