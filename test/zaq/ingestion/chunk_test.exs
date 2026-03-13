defmodule Zaq.Ingestion.ChunkTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.{Chunk, Document}

  setup do
    {:ok, doc} =
      Document.create(%{
        source: "test_doc.md",
        content: "# Test\n\nContent here."
      })

    %{document: doc}
  end

  @chunk_attrs %{
    content: "This is a test chunk.",
    chunk_index: 0,
    section_path: ["Introduction"],
    metadata: %{"section_type" => "heading", "section_level" => 1}
  }

  defp chunk_attrs(doc, overrides \\ %{}) do
    @chunk_attrs
    |> Map.put(:document_id, doc.id)
    |> Map.merge(overrides)
  end

  describe "changeset/2" do
    test "valid with required fields", %{document: doc} do
      changeset = Chunk.changeset(%Chunk{}, chunk_attrs(doc))
      assert changeset.valid?
    end

    test "invalid without document_id" do
      changeset = Chunk.changeset(%Chunk{}, Map.delete(@chunk_attrs, :document_id))
      refute changeset.valid?
    end

    test "invalid without content", %{document: doc} do
      changeset = Chunk.changeset(%Chunk{}, chunk_attrs(doc, %{content: nil}))
      refute changeset.valid?
    end

    test "invalid without chunk_index", %{document: doc} do
      changeset = Chunk.changeset(%Chunk{}, chunk_attrs(doc, %{chunk_index: nil}))
      refute changeset.valid?
    end

    test "defaults section_path to empty list", %{document: doc} do
      attrs = chunk_attrs(doc) |> Map.delete(:section_path)
      changeset = Chunk.changeset(%Chunk{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :section_path) == []
    end

    test "defaults metadata to empty map", %{document: doc} do
      attrs = chunk_attrs(doc) |> Map.delete(:metadata)
      changeset = Chunk.changeset(%Chunk{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :metadata) == %{}
    end
  end

  describe "create/1" do
    test "inserts a chunk", %{document: doc} do
      assert {:ok, chunk} = Chunk.create(chunk_attrs(doc))
      assert chunk.content == "This is a test chunk."
      assert chunk.chunk_index == 0
      assert chunk.section_path == ["Introduction"]
      assert chunk.document_id == doc.id
    end

    test "enforces foreign key constraint" do
      attrs = Map.put(@chunk_attrs, :document_id, -1)
      assert {:error, changeset} = Chunk.create(attrs)
      assert {"does not exist", _} = changeset.errors[:document_id]
    end
  end

  describe "create_with_embedding/2" do
    test "inserts a chunk with embedding", %{document: doc} do
      dimension =
        Application.get_env(:zaq, Zaq.Embedding.Client, []) |> Keyword.get(:dimension, 3584)

      embedding = List.duplicate(0.1, dimension)
      assert {:ok, chunk} = Chunk.create_with_embedding(chunk_attrs(doc), embedding)
      assert chunk.embedding != nil
    end
  end

  describe "list_by_document/1" do
    test "returns chunks ordered by chunk_index", %{document: doc} do
      {:ok, _} = Chunk.create(chunk_attrs(doc, %{chunk_index: 2, content: "Third"}))
      {:ok, _} = Chunk.create(chunk_attrs(doc, %{chunk_index: 0, content: "First"}))
      {:ok, _} = Chunk.create(chunk_attrs(doc, %{chunk_index: 1, content: "Second"}))

      chunks = Chunk.list_by_document(doc.id)
      assert length(chunks) == 3
      assert Enum.map(chunks, & &1.chunk_index) == [0, 1, 2]
    end

    test "returns empty list for document with no chunks", %{document: _doc} do
      {:ok, other_doc} = Document.create(%{source: "other.md", content: "Other"})
      assert Chunk.list_by_document(other_doc.id) == []
    end
  end

  describe "delete_by_document/1" do
    test "deletes all chunks for a document", %{document: doc} do
      {:ok, _} = Chunk.create(chunk_attrs(doc, %{chunk_index: 0}))
      {:ok, _} = Chunk.create(chunk_attrs(doc, %{chunk_index: 1}))

      assert {2, nil} = Chunk.delete_by_document(doc.id)
      assert Chunk.list_by_document(doc.id) == []
    end
  end

  describe "count_by_document/1" do
    test "returns chunk count", %{document: doc} do
      {:ok, _} = Chunk.create(chunk_attrs(doc, %{chunk_index: 0}))
      {:ok, _} = Chunk.create(chunk_attrs(doc, %{chunk_index: 1}))

      assert Chunk.count_by_document(doc.id) == 2
    end

    test "returns 0 for document with no chunks", %{document: _doc} do
      {:ok, other_doc} = Document.create(%{source: "empty.md", content: "Empty"})
      assert Chunk.count_by_document(other_doc.id) == 0
    end
  end

  describe "role_id" do
    test "chunk with role_id is valid", %{document: doc} do
      {:ok, role} =
        Zaq.Accounts.create_role(%{name: "chunk_role_#{System.unique_integer([:positive])}"})

      changeset = Chunk.changeset(%Chunk{}, chunk_attrs(doc, %{role_id: role.id}))
      assert changeset.valid?
    end

    test "chunk with nil role_id is valid", %{document: doc} do
      changeset = Chunk.changeset(%Chunk{}, chunk_attrs(doc, %{role_id: nil}))
      assert changeset.valid?
    end
  end

  describe "document cascade delete" do
    test "deleting document removes its chunks", %{document: doc} do
      {:ok, chunk} = Chunk.create(chunk_attrs(doc, %{chunk_index: 0}))
      {:ok, _} = Document.delete(doc)
      assert Zaq.Repo.get(Chunk, chunk.id) == nil
    end
  end
end
