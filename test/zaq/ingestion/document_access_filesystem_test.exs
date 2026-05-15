defmodule Zaq.Ingestion.DocumentAccessFilesystemTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Chunk, Document, DocumentAccess, Sidecar}

  import Zaq.SystemConfigFixtures

  setup do
    seed_embedding_config(%{model: "test-model", dimension: "1536"})

    tmp =
      Path.join(System.tmp_dir!(), "doc_access_fs_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: tmp)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp create_doc(source) do
    {:ok, doc} =
      Document.create(%{source: source, content: "content for #{source}", metadata: %{}})

    doc
  end

  defp insert_chunk_for(doc) do
    {:ok, _chunk} = Chunk.create(%{document_id: doc.id, content: "chunk", chunk_index: 0})
  end

  describe "list_files_with_ingestion_status/1 — skip_permissions: true (filesystem walk)" do
    test "tags indexed files as ingested: true and unindexed as ingested: false", %{tmp: tmp} do
      File.write!("#{tmp}/indexed.md", "content")
      File.write!("#{tmp}/unindexed.txt", "other")
      doc = create_doc("indexed.md")
      insert_chunk_for(doc)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)

      indexed = Enum.find(result, fn r -> r.source == "indexed.md" end)
      unindexed = Enum.find(result, fn r -> r.source == "unindexed.txt" end)

      assert indexed != nil
      assert indexed.ingested == true

      assert unindexed != nil
      assert unindexed.ingested == false
    end

    test "file with no DB entry gets ingested: false", %{tmp: tmp} do
      File.write!("#{tmp}/raw.md", "raw")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      entry = Enum.find(result, fn r -> r.source == "raw.md" end)

      assert entry != nil
      assert entry.ingested == false
    end

    test "nil source_filter includes all files", %{tmp: tmp} do
      File.write!("#{tmp}/a.md", "a")
      File.write!("#{tmp}/b.md", "b")

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: nil
        )

      sources = Enum.map(result, & &1.source)
      assert "a.md" in sources
      assert "b.md" in sources
    end

    test "empty source_filter includes all files", %{tmp: tmp} do
      File.write!("#{tmp}/c.md", "c")

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: []
        )

      sources = Enum.map(result, & &1.source)
      assert "c.md" in sources
    end

    test "folder source_filter restricts to files under that folder", %{tmp: tmp} do
      subdir = "#{tmp}/subdir"
      File.mkdir_p!(subdir)
      File.write!("#{subdir}/in.md", "in folder")
      File.write!("#{tmp}/outside.md", "outside folder")

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: ["subdir"]
        )

      sources = Enum.map(result, & &1.source)
      assert Enum.any?(sources, &String.starts_with?(&1, "subdir/"))
      refute "outside.md" in sources
    end

    test "exact file source_filter matches only that specific file", %{tmp: tmp} do
      File.write!("#{tmp}/target.md", "target")
      File.write!("#{tmp}/other.md", "other")

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: ["target.md"]
        )

      sources = Enum.map(result, & &1.source)
      assert "target.md" in sources
      refute "other.md" in sources
    end

    test "multiple folder prefixes are OR-ed together", %{tmp: tmp} do
      dira = "#{tmp}/dira"
      dirb = "#{tmp}/dirb"
      dirc = "#{tmp}/dirc"
      File.mkdir_p!(dira)
      File.mkdir_p!(dirb)
      File.mkdir_p!(dirc)
      File.write!("#{dira}/a.md", "a")
      File.write!("#{dirb}/b.md", "b")
      File.write!("#{dirc}/c.md", "c")

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: ["dira", "dirb"]
        )

      sources = Enum.map(result, & &1.source)
      assert Enum.any?(sources, &String.starts_with?(&1, "dira/"))
      assert Enum.any?(sources, &String.starts_with?(&1, "dirb/"))
      refute Enum.any?(sources, &String.starts_with?(&1, "dirc/"))
    end

    test "sidecar .md is excluded when its source file exists", %{tmp: tmp} do
      File.write!("#{tmp}/slides.pptx", "binary")
      File.write!("#{tmp}/slides.md", "sidecar content")

      Document.create(%{
        source: "slides.md",
        content: "sidecar content",
        metadata: Sidecar.sidecar_metadata("slides.pptx")
      })

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert "slides.pptx" in sources
      refute "slides.md" in sources
    end

    test "standalone .md with no paired source file is not excluded", %{tmp: tmp} do
      File.write!("#{tmp}/notes.md", "standalone")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert "notes.md" in sources
    end

    test "ingested doc carries its title field", %{tmp: tmp} do
      File.write!("#{tmp}/titled.md", "content")

      {:ok, doc} =
        Document.create(%{source: "titled.md", content: "c", title: "My Title", metadata: %{}})

      insert_chunk_for(doc)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      entry = Enum.find(result, fn r -> r.source == doc.source end)

      assert entry != nil
      assert entry.ingested == true
      assert entry.title == "My Title"
    end
  end
end
