defmodule Zaq.Ingestion.ListDocumentSourcesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document

  # Seeds a top-level document (no chunk metadata) with the given source path.
  defp seed(source) do
    {:ok, doc} = Document.create(%{source: source})
    doc
  end

  # ── Name search (no "/" in query) ──────────────────────────────────────────

  describe "list_document_sources/1 — name search" do
    test "returns the matching folder once, not once per file inside it" do
      seed("archives/zaq/file1.pdf")
      seed("archives/zaq/file2.pdf")
      seed("archives/zaq/file3.pdf")

      results = Ingestion.list_document_sources("zaq")
      labels = Enum.map(results, & &1.label)

      assert labels == ["zaq"]
    end

    test "includes individual files whose filename matches the query (no slash)" do
      seed("archives/zaq/report.pdf")

      results = Ingestion.list_document_sources("report")
      labels = Enum.map(results, & &1.label)

      assert "report.pdf" in labels
      assert hd(results).type == :file
    end

    test "returns one entry per unique {connector, label}, keeping the shallowest path" do
      seed("archives/zaq/file.pdf")
      # deeper "zaq" inside a sibling folder — should be suppressed
      seed("archives/other/zaq/nested.pdf")

      results = Ingestion.list_document_sources("zaq")

      assert length(results) == 1
      assert hd(results).source_prefix == "archives/zaq"
    end

    test "returns multiple matching folders when several share the same prefix" do
      seed("archives/zaq/file.pdf")
      seed("archives/zaq-pptx/slide.pptx")

      results = Ingestion.list_document_sources("za")
      labels = results |> Enum.map(& &1.label) |> Enum.sort()

      assert labels == ["zaq", "zaq-pptx"]
    end

    test "returns empty list when nothing matches" do
      seed("archives/zaq/file.pdf")

      assert Ingestion.list_document_sources("nomatch") == []
    end
  end

  # ── Path browse (query contains "/") ───────────────────────────────────────

  describe "list_document_sources/1 — path browse" do
    test "returns only direct children of the named folder, plus the folder itself as current_folder" do
      seed("archives/zaq/file1.pdf")
      seed("archives/zaq/file2.pdf")
      seed("archives/zaq-pptx/other.pptx")

      results = Ingestion.list_document_sources("zaq/")

      child_labels =
        results
        |> Enum.reject(&(&1.type == :current_folder))
        |> Enum.map(& &1.label)
        |> Enum.sort()

      assert child_labels == ["file1.pdf", "file2.pdf"]
      refute "other.pptx" in child_labels
      assert Enum.any?(results, &(&1.type == :current_folder and &1.label == "zaq"))
    end

    test "does not leak files from a sibling folder with a similar name" do
      seed("archives/zaq/real.pdf")
      # "archives/zaq-pptx/zaq/nested.pdf" also contains "zaq/" — must be excluded
      seed("archives/zaq-pptx/zaq/nested.pdf")

      results = Ingestion.list_document_sources("zaq/")
      labels = Enum.map(results, & &1.label)

      assert "real.pdf" in labels
      refute "nested.pdf" in labels
    end

    test "filters children by the fragment typed after the slash" do
      seed("archives/zaq/report.pdf")
      seed("archives/zaq/readme.md")
      seed("archives/zaq/other.pdf")

      results = Ingestion.list_document_sources("zaq/re")
      labels = results |> Enum.map(& &1.label) |> Enum.sort()

      assert labels == ["readme.md", "report.pdf"]
      refute "other.pdf" in Enum.map(results, & &1.label)
    end

    test "surfaces a deep file as its immediate parent subfolder, not as the file itself" do
      seed("archives/zaq/subfolder/deep.pdf")
      seed("archives/zaq/direct.pdf")

      results = Ingestion.list_document_sources("zaq/")

      subfolder_entry = Enum.find(results, &(&1.label == "subfolder"))
      direct_entry = Enum.find(results, &(&1.label == "direct.pdf"))

      assert subfolder_entry != nil
      assert subfolder_entry.type == :folder

      assert direct_entry != nil
      assert direct_entry.type == :file

      refute Enum.any?(results, &(&1.label == "deep.pdf"))
    end

    test "includes the folder itself as :current_folder at the top, followed by children" do
      seed("archives/zaq/file.pdf")

      results = Ingestion.list_document_sources("zaq/")
      labels = Enum.map(results, & &1.label)

      assert List.first(results).type == :current_folder
      assert List.first(results).label == "zaq"
      assert "file.pdf" in labels
    end

    test "browse with multiple connectors sharing same subfolder name yields exactly one current_folder entry" do
      # Two connectors each have a "zaq" subfolder; current_folder is deduped by label
      seed("documents/zaq/file1.pdf")
      seed("sharepoint/zaq/slide1.pptx")

      results = Ingestion.list_document_sources("zaq/")

      current_folder_entries = Enum.filter(results, &(&1.type == :current_folder))

      assert length(current_folder_entries) == 1
      assert hd(current_folder_entries).label == "zaq"
    end

    test "browse with child_query non-empty does not include a current_folder entry" do
      seed("archives/zaq/report.pdf")
      seed("archives/zaq/readme.md")

      results = Ingestion.list_document_sources("zaq/re")

      current_folder_entries = Enum.filter(results, &(&1.type == :current_folder))

      assert current_folder_entries == []
    end

    test "browse with child_query non-empty returns only matching children" do
      seed("archives/zaq/report.pdf")
      seed("archives/zaq/readme.md")
      seed("archives/zaq/other.pdf")

      results = Ingestion.list_document_sources("zaq/re")
      labels = results |> Enum.map(& &1.label) |> Enum.sort()

      assert "readme.md" in labels
      assert "report.pdf" in labels
      refute "other.pdf" in labels
    end
  end
end
