defmodule Zaq.Ingestion.DocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.Document

  @valid_attrs %{
    source: "test_document.md",
    content: "# Hello\n\nThis is a test document.",
    content_type: "markdown"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Document.changeset(%Document{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without source" do
      attrs = Map.delete(@valid_attrs, :source)
      changeset = Document.changeset(%Document{}, attrs)
      refute changeset.valid?
    end

    test "invalid without content" do
      attrs = Map.delete(@valid_attrs, :content)
      changeset = Document.changeset(%Document{}, attrs)
      refute changeset.valid?
    end

    test "invalid with unsupported content_type" do
      attrs = Map.put(@valid_attrs, :content_type, "pdf")
      changeset = Document.changeset(%Document{}, attrs)
      refute changeset.valid?
    end

    test "defaults content_type to markdown" do
      attrs = Map.delete(@valid_attrs, :content_type)
      changeset = Document.changeset(%Document{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :content_type) == "markdown"
    end

    test "derives title from source filename when not provided" do
      changeset = Document.changeset(%Document{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :title) == "test_document"
    end

    test "keeps explicit title when provided" do
      attrs = Map.put(@valid_attrs, :title, "Custom Title")
      changeset = Document.changeset(%Document{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :title) == "Custom Title"
    end
  end

  describe "create/1" do
    test "inserts a document" do
      assert {:ok, doc} = Document.create(@valid_attrs)
      assert doc.source == "test_document.md"
      assert doc.content == "# Hello\n\nThis is a test document."
      assert doc.content_type == "markdown"
      assert doc.title == "test_document"
    end

    test "enforces unique source" do
      assert {:ok, _} = Document.create(@valid_attrs)
      assert {:error, changeset} = Document.create(@valid_attrs)
      assert {"has already been taken", _} = changeset.errors[:source]
    end
  end

  describe "upsert/1" do
    test "inserts new document" do
      assert {:ok, doc} = Document.upsert(@valid_attrs)
      assert doc.source == "test_document.md"
    end

    test "updates existing document on conflict" do
      {:ok, original} = Document.create(@valid_attrs)

      updated_attrs = %{@valid_attrs | content: "Updated content"}
      {:ok, updated} = Document.upsert(updated_attrs)

      assert updated.id == original.id
      assert updated.content == "Updated content"
    end
  end

  describe "get/1 and get!/1" do
    test "get returns document by id" do
      {:ok, doc} = Document.create(@valid_attrs)
      assert Document.get(doc.id).source == "test_document.md"
    end

    test "get returns nil for nonexistent id" do
      assert Document.get(-1) == nil
    end

    test "get! raises for nonexistent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Document.get!(-1)
      end
    end
  end

  describe "get_by_source/1" do
    test "returns document by source" do
      {:ok, _} = Document.create(@valid_attrs)
      doc = Document.get_by_source("test_document.md")
      assert doc.source == "test_document.md"
    end

    test "returns nil for nonexistent source" do
      assert Document.get_by_source("nonexistent.md") == nil
    end
  end

  describe "list/0" do
    test "returns all documents" do
      {:ok, _} = Document.create(%{@valid_attrs | source: "a.md"})
      {:ok, _} = Document.create(%{@valid_attrs | source: "b.md"})

      docs = Document.list()
      sources = Enum.map(docs, & &1.source) |> Enum.sort()
      assert sources == ["a.md", "b.md"]
    end
  end

  describe "delete/1" do
    test "deletes a document" do
      {:ok, doc} = Document.create(@valid_attrs)
      assert {:ok, _} = Document.delete(doc)
      assert Document.get(doc.id) == nil
    end
  end
end
