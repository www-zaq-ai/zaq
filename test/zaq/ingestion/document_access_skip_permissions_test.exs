defmodule Zaq.Ingestion.DocumentAccessSkipPermissionsTest do
  # async: false — modifies application env and writes to the filesystem
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Document, DocumentAccess}

  @test_base "test/tmp/document_access_skip_permissions"

  setup do
    File.rm_rf!(@test_base)
    File.mkdir_p!(@test_base)

    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@test_base)
    end)

    :ok
  end

  defp write_file(rel_path, content \\ "content") do
    abs = Path.join(@test_base, rel_path)
    abs |> Path.dirname() |> File.mkdir_p!()
    File.write!(abs, content)
    rel_path
  end

  defp create_doc(source) do
    {:ok, doc} = Document.create(%{source: source, content: "content for #{source}"})
    doc
  end

  describe "list_files_with_ingestion_status/1 — skip_permissions: true" do
    test "file on disk that is ingested is tagged ingested: true" do
      source = write_file("folder/ingested.md")
      _doc = create_doc(source)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      entry = Enum.find(result, fn r -> r.source == source end)

      assert entry != nil
      assert entry.ingested == true
    end

    test "file on disk that is NOT in the DB is tagged ingested: false" do
      source = write_file("folder/not_ingested.md")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      entry = Enum.find(result, fn r -> r.source == source end)

      assert entry != nil
      assert entry.ingested == false
    end

    test "mixed: returns both ingested and non-ingested files" do
      ingested_source = write_file("mixed/ingested.md")
      not_ingested_source = write_file("mixed/not_ingested.md")
      _doc = create_doc(ingested_source)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)

      ingested_entry = Enum.find(result, fn r -> r.source == ingested_source end)
      not_ingested_entry = Enum.find(result, fn r -> r.source == not_ingested_source end)

      assert ingested_entry != nil
      assert ingested_entry.ingested == true
      assert not_ingested_entry != nil
      assert not_ingested_entry.ingested == false
    end

    test "source_filter restricts results to matching folder" do
      in_source = write_file("target-folder/file.md")
      out_source = write_file("other-folder/file.md")

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: ["target-folder"]
        )

      sources = Enum.map(result, & &1.source)
      assert in_source in sources
      refute out_source in sources
    end

    test "source_filter with exact file path matches only that file" do
      target = write_file("exact-filter/target.md")
      sibling = write_file("exact-filter/sibling.md")

      result =
        DocumentAccess.list_files_with_ingestion_status(
          skip_permissions: true,
          source_filter: [target]
        )

      sources = Enum.map(result, & &1.source)
      assert target in sources
      refute sibling in sources
    end

    test "walks nested subdirectories" do
      shallow = write_file("nested/file.md")
      deep = write_file("nested/sub/deep.md")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert shallow in sources
      assert deep in sources
    end

    test "sidecar .md file is excluded when a paired source file exists" do
      write_file("sidecar/report.pdf")
      md_source = write_file("sidecar/report.md")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert Enum.any?(sources, &String.ends_with?(&1, "report.pdf"))
      refute md_source in sources
    end

    test "standalone .md file (no paired source) is NOT excluded" do
      md_source = write_file("standalone/notes.md")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert md_source in sources
    end

    test "ingested doc with no file on disk does not appear in results" do
      source = "ghost/missing.md"
      _doc = create_doc(source)

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      refute Enum.any?(result, fn r -> r.source == source end)
    end
  end
end
