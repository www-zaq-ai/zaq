defmodule Zaq.Ingestion.DocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.Document
  alias Zaq.Repo

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

    test "valid without content (content is optional for upload tracking)" do
      attrs = Map.delete(@valid_attrs, :content)
      changeset = Document.changeset(%Document{}, attrs)
      assert changeset.valid?
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

  describe "watch_statuses/0" do
    test "returns the expected statuses" do
      assert Document.watch_statuses() == ~w(unwatched pending watched error)
    end

    test "accepts known watch statuses" do
      Enum.each(Document.watch_statuses(), fn status ->
        attrs = Map.put(@valid_attrs, :watch_status, status)
        assert Document.changeset(%Document{}, attrs).valid?
      end)
    end

    test "rejects unknown watch statuses" do
      attrs = Map.put(@valid_attrs, :watch_status, "archived")
      refute Document.changeset(%Document{}, attrs).valid?
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

  describe "insert_new/1" do
    test "returns existing document on source conflict without overwriting content" do
      source = "tracked/existing-#{System.unique_integer([:positive])}.md"

      {:ok, existing} =
        Document.create(%{
          source: source,
          title: "Original title",
          content: "original content",
          content_type: "markdown",
          metadata: %{"origin" => "original"}
        })

      {:ok, returned} =
        Document.insert_new(%{
          "source" => source,
          "title" => "Replacement title",
          "content" => "replacement content",
          "content_type" => "markdown",
          "metadata" => %{"origin" => "replacement"}
        })

      assert returned.id == existing.id
      assert returned.source == source
      assert returned.title == "Original title"
      assert returned.content == "original content"
      assert returned.metadata == %{"origin" => "original"}

      persisted = Document.get_by_source(source)
      assert persisted.id == existing.id
      assert persisted.title == "Original title"
      assert persisted.content == "original content"
      assert persisted.metadata == %{"origin" => "original"}
    end

    test "returns existing document on atom-key source conflict" do
      source = "tracked/atom-existing-#{System.unique_integer([:positive])}.md"
      {:ok, existing} = Document.create(%{source: source, content: "original content"})

      assert {:ok, returned} =
               Document.insert_new(%{source: source, content: "replacement content"})

      assert returned.id == existing.id
      assert returned.content == "original content"
      assert Document.get_by_source(source).content == "original content"
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

  describe "ids_by_source/1" do
    test "maps existing sources and omits missing sources" do
      {:ok, first} = Document.create(%{source: "ids/first.md", content: "first"})
      {:ok, second} = Document.create(%{source: "ids/second.md", content: "second"})

      assert Document.ids_by_source([
               "ids/first.md",
               "ids/second.md",
               "ids/first.md",
               "ids/missing.md"
             ]) ==
               %{"ids/first.md" => first.id, "ids/second.md" => second.id}
    end

    test "returns an empty map for an empty source list" do
      assert Document.ids_by_source([]) == %{}
    end
  end

  describe "rename_source_prefix_query/2" do
    test "renames only sources under the exact prefix" do
      old_prefix = "rename/source-#{System.unique_integer([:positive])}"
      new_prefix = "renamed/source-#{System.unique_integer([:positive])}"

      {:ok, matching} =
        Document.create(%{source: "#{old_prefix}/nested/file.md", content: "match"})

      {:ok, exact} = Document.create(%{source: old_prefix, content: "exact"})
      {:ok, sibling} = Document.create(%{source: "#{old_prefix}x/file.md", content: "sibling"})
      {:ok, unrelated} = Document.create(%{source: "other/file.md", content: "other"})

      assert {1, _} =
               Repo.update_all(Document.rename_source_prefix_query(old_prefix, new_prefix), [])

      assert Document.get(matching.id).source == "#{new_prefix}/nested/file.md"
      assert Document.get(exact.id).source == old_prefix
      assert Document.get(sibling.id).source == "#{old_prefix}x/file.md"
      assert Document.get(unrelated.id).source == "other/file.md"
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
