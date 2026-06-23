defmodule Zaq.Ingestion.DirectorySnapshotTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, FileExplorer, IngestJob, Sidecar}
  alias Zaq.Repo

  @volume "default"

  defp ufolder(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp make_dir(path), do: :ok = FileExplorer.create_directory(@volume, path)

  defp make_file(path, content \\ "# content") do
    {:ok, _} = FileExplorer.upload(@volume, path, content)
  end

  defp make_primary(source, content \\ "ingested") do
    {:ok, _doc} = Document.create(%{source: source, content: content})
  end

  defp make_sidecar(sidecar_source, primary_source, content \\ "extracted") do
    {:ok, _doc} =
      Document.create(%{
        source: sidecar_source,
        content: content,
        metadata: Sidecar.sidecar_metadata(primary_source)
      })
  end

  # Reads folder stats for a named subfolder from the root-level snapshot.
  defp folder_stats(folder_name) do
    {:ok, snapshot} = Ingestion.directory_snapshot(@volume, ".", nil)
    Map.get(snapshot.ingestion_map, folder_name)
  end

  # ── Case 1: plain folder, no sidecars ────────────────────────────────────────

  describe "folder stats — no sidecars" do
    test "counts all ingested primary documents" do
      folder = ufolder("plain")
      make_dir(folder)
      make_file(Path.join(folder, "a.md"))
      make_file(Path.join(folder, "b.md"))
      make_primary("default/#{folder}/a.md")
      make_primary("default/#{folder}/b.md")

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats = folder_stats(folder)
      assert stats.file_count == 2
      assert stats.ingested_count == 2
    end

    test "un-ingested file (nil content) is counted in total but not ingested" do
      folder = ufolder("plain_pending")
      make_dir(folder)
      make_file(Path.join(folder, "pending.md"))
      {:ok, _} = Document.create(%{source: "default/#{folder}/pending.md", content: nil})

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats = folder_stats(folder)
      assert stats.file_count == 1
      assert stats.ingested_count == 0
    end
  end

  describe "job status lookup" do
    test "matches legacy root file paths with ./ prefix" do
      path = "legacy_status_#{System.unique_integer([:positive])}.md"
      make_file(path)

      %IngestJob{}
      |> IngestJob.changeset(%{
        file_path: "./" <> path,
        volume_name: @volume,
        status: "pending",
        mode: "async"
      })
      |> Repo.insert!()

      on_exit(fn -> FileExplorer.delete(@volume, path) end)

      {:ok, snapshot} = Ingestion.directory_snapshot(@volume, ".", nil)

      assert snapshot.ingestion_map[path].job_status == "pending"
    end
  end

  # ── Case 2: PDF + auto-generated sidecar MD ──────────────────────────────────
  #
  # When a PDF is ingested a sidecar .md is generated and stored as a Document
  # with metadata["source_document_source"] set. That sidecar must NOT be counted
  # in file_count or ingested_count — the user only has one visible file (the PDF).

  describe "folder stats — PDF with auto-generated sidecar" do
    test "sidecar MD is not counted in file_count or ingested_count" do
      folder = ufolder("sidecar")
      pdf_source = "default/#{folder}/report.pdf"
      sidecar_source = "default/#{folder}/report.md"

      make_dir(folder)
      make_file(Path.join(folder, "report.pdf"), "%PDF")
      make_file(Path.join(folder, "report.md"), "extracted")
      make_primary(pdf_source)
      make_sidecar(sidecar_source, pdf_source)

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats = folder_stats(folder)

      assert stats.file_count == 1,
             "Only the PDF should count; its sidecar must be excluded (got #{stats.file_count})"

      assert stats.ingested_count == 1
    end

    test "two PDFs with sidecars — file_count == 2, ingested_count == 2" do
      folder = ufolder("two_pdfs")
      make_dir(folder)

      Enum.each(["alpha", "beta"], fn name ->
        pdf_source = "default/#{folder}/#{name}.pdf"
        sidecar_source = "default/#{folder}/#{name}.md"
        make_file(Path.join(folder, "#{name}.pdf"), "%PDF")
        make_file(Path.join(folder, "#{name}.md"), "extracted")
        make_primary(pdf_source)
        make_sidecar(sidecar_source, pdf_source)
      end)

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats = folder_stats(folder)
      assert stats.file_count == 2
      assert stats.ingested_count == 2
    end
  end

  # ── Case 3: user-written .md deleted; PDF then ingested generates new sidecar .md
  #
  # Sequence: product.md (user) + product.pdf exist → user deletes product.md →
  # ingests product.pdf → new product.md sidecar created.
  # The sidecar product.md must NOT be counted as a separate file.

  describe "folder stats — original MD deleted, PDF sidecar MD takes its place" do
    test "sidecar MD replacing a deleted user .md is excluded from file_count" do
      folder = ufolder("replace_md")
      pdf_source = "default/#{folder}/product.pdf"
      sidecar_source = "default/#{folder}/product.md"

      make_dir(folder)
      make_file(Path.join(folder, "product.pdf"), "%PDF")
      make_file(Path.join(folder, "product.md"), "extracted")

      # The original product.md was deleted; only the PDF primary doc and its
      # sidecar now exist in the DB.
      make_primary(pdf_source)
      make_sidecar(sidecar_source, pdf_source)

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats = folder_stats(folder)
      assert stats.file_count == 1, "product.md is a sidecar; only product.pdf is primary"
      assert stats.ingested_count == 1
    end
  end

  # ── Case 4: mixed — regular .md files + PDF with sidecar ─────────────────────

  describe "folder stats — mixed primary files and sidecar" do
    test "regular MDs and a PDF are counted; their sidecar is excluded" do
      folder = ufolder("mixed")
      make_dir(folder)

      # Two user-written docs
      make_file(Path.join(folder, "readme.md"))
      make_file(Path.join(folder, "spec.md"))
      make_primary("default/#{folder}/readme.md")
      make_primary("default/#{folder}/spec.md")

      # One PDF with its sidecar
      pdf_source = "default/#{folder}/diagram.pdf"
      sidecar_source = "default/#{folder}/diagram.md"
      make_file(Path.join(folder, "diagram.pdf"), "%PDF")
      make_file(Path.join(folder, "diagram.md"), "extracted")
      make_primary(pdf_source)
      make_sidecar(sidecar_source, pdf_source)

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats = folder_stats(folder)

      assert stats.file_count == 3,
             "readme.md + spec.md + diagram.pdf = 3; diagram.md sidecar excluded (got #{stats.file_count})"

      assert stats.ingested_count == 3
    end
  end

  # ── Case 5: subfolder deletion ────────────────────────────────────────────────
  #
  # After deleting a subfolder, its documents are removed from DB. The parent
  # folder's file_count must drop accordingly — including any sidecars the
  # subfolder contained (so they don't ghost into the parent's count).

  describe "folder stats — subfolder deletion" do
    test "deleting a subfolder removes its docs from the parent folder count" do
      folder = ufolder("parent_del")
      subfolder = Path.join(folder, "sub")

      make_dir(folder)
      make_dir(subfolder)

      make_file(Path.join(folder, "a.md"))
      make_file(Path.join(folder, "b.md"))
      make_primary("default/#{folder}/a.md")
      make_primary("default/#{folder}/b.md")

      make_file(Path.join(subfolder, "c.md"))
      make_file(Path.join(subfolder, "d.md"))
      make_primary("default/#{subfolder}/c.md")
      make_primary("default/#{subfolder}/d.md")

      # Parent recursively counts all 4 docs before delete
      stats_before = folder_stats(folder)
      assert stats_before.file_count == 4

      assert :ok = Ingestion.delete_path(@volume, subfolder, "directory")

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats_after = folder_stats(folder)

      assert stats_after.file_count == 2,
             "After subfolder delete, only 2 parent docs should remain (got #{stats_after.file_count})"

      assert stats_after.ingested_count == 2
    end

    test "subfolder with PDF+sidecar: deleting subfolder leaves no ghost documents in parent count" do
      folder = ufolder("parent_pdf_del")
      subfolder = Path.join(folder, "sub")

      make_dir(folder)
      make_dir(subfolder)

      # Parent: 2 regular files
      make_file(Path.join(folder, "a.md"))
      make_file(Path.join(folder, "b.md"))
      make_primary("default/#{folder}/a.md")
      make_primary("default/#{folder}/b.md")

      # Subfolder: 1 PDF + its sidecar
      pdf_source = "default/#{subfolder}/doc.pdf"
      sidecar_source = "default/#{subfolder}/doc.md"
      make_file(Path.join(subfolder, "doc.pdf"), "%PDF")
      make_file(Path.join(subfolder, "doc.md"), "extracted")
      make_primary(pdf_source)
      make_sidecar(sidecar_source, pdf_source)

      # With the sidecar fix, parent sees 2 (parent) + 1 (subfolder PDF) = 3
      stats_before = folder_stats(folder)

      assert stats_before.file_count == 3,
             "2 parent files + 1 subfolder PDF (sidecar excluded) = 3 (got #{stats_before.file_count})"

      assert :ok = Ingestion.delete_path(@volume, subfolder, "directory")

      on_exit(fn -> FileExplorer.delete_directory(@volume, folder) end)

      stats_after = folder_stats(folder)

      assert stats_after.file_count == 2,
             "After deleting subfolder (PDF + sidecar), only 2 parent docs remain (got #{stats_after.file_count})"

      assert stats_after.ingested_count == 2
    end
  end
end
