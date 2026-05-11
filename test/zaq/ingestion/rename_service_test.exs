defmodule Zaq.Ingestion.RenameServiceTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, Permission, RenameService, Sidecar}
  alias Zaq.Repo

  @test_base "test/tmp/rename_service"

  setup do
    File.rm_rf!(@test_base)
    File.mkdir_p!(Path.join(@test_base, "zaq"))
    File.write!(Path.join(@test_base, "zaq/doc.md"), "# Hello")
    File.write!(Path.join(@test_base, "zaq/report.pdf"), "%PDF-1.0")

    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@test_base)
    end)

    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{
        "full_name" => "Tester #{unique}",
        "email" => "tester#{unique}@test.com"
      })

    {:ok, doc} = Document.create(%{source: "zaq/doc.md", content: "# Hello"})

    {:ok, source_doc} =
      Document.create(%{
        source: "zaq/report.pdf",
        content: "",
        metadata: Sidecar.source_metadata("zaq/report.md")
      })

    {:ok, sidecar_doc} =
      Document.create(%{
        source: "zaq/report.md",
        content: "# Report",
        metadata: Sidecar.sidecar_metadata("zaq/report.pdf")
      })

    {:ok, _perm} =
      %Permission{}
      |> Permission.changeset(%{
        resource_id: to_string(doc.id),
        person_id: person.id,
        access_rights: ["read"]
      })
      |> Repo.insert()

    %{doc: doc, person: person, source_doc: source_doc, sidecar_doc: sidecar_doc}
  end

  # Reproduces issue #331: renaming a folder leaves Document records pointing to
  # the old path, making sidecar associations and permissions unreachable by
  # the new path.
  describe "rename_entry/3 for a directory" do
    test "updates document source paths inside the renamed folder", %{doc: doc} do
      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      updated_doc = Document.get_by_source("product/doc.md")
      assert updated_doc != nil, "Document should be reachable at the renamed path"
      assert updated_doc.id == doc.id
    end

    test "updates sidecar metadata pointers after folder rename", %{
      source_doc: source_doc,
      sidecar_doc: sidecar_doc
    } do
      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      updated_source = Repo.get!(Document, source_doc.id)
      updated_sidecar = Repo.get!(Document, sidecar_doc.id)

      assert Sidecar.sidecar_source(updated_source) == "product/report.md",
             "sidecar_source metadata must point to the new path"

      assert updated_sidecar.metadata["source_document_source"] == "product/report.pdf",
             "source_document_source metadata must point to the new path"
    end

    test "preserves permissions after folder rename", %{person: person} do
      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      updated_doc = Document.get_by_source("product/doc.md")
      assert updated_doc != nil, "Document must be findable at new path to check permissions"

      perm =
        Repo.get_by(Permission,
          resource_id: to_string(updated_doc.id),
          person_id: person.id
        )

      assert perm != nil, "Permission should survive the folder rename"
      assert perm.access_rights == ["read"]
    end

    test "also renames legacy absolute-path document sources (same folder name)", %{} do
      # Reproduces the bug where documents ingested with a broken absolute_to_source
      # (stored as "volume_name/<abs_path_without_leading_slash>/...") were skipped
      # by the rename query because neither "folder/..." nor "volume/folder/..."
      # matched the absolute-path prefix.
      base = Application.get_env(:zaq, Zaq.Ingestion)[:base_path] |> Path.expand()
      abs_prefix = "default/" <> String.trim_leading(Path.join(base, "zaq"), "/")
      legacy_source = abs_prefix <> "/legacy.md"

      {:ok, legacy_doc} = Document.create(%{source: legacy_source, content: "legacy"})

      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      updated = Repo.get!(Document, legacy_doc.id)

      assert updated.source == "default/product/legacy.md",
             "Legacy absolute-path source must be rewritten to relative format on rename"
    end

    test "fixes stranded legacy sources from a previous untracked rename", %{} do
      # Simulates the scenario where folder A was renamed to B without the fix
      # (legacy docs still say A), and now B is being renamed to C. The sync step
      # must detect that A's legacy docs correspond to files now in C and update them.
      base = Application.get_env(:zaq, Zaq.Ingestion)[:base_path] |> Path.expand()

      # Create a file in "zaq" on disk and a legacy doc pointing to it with an old
      # absolute-path source that reflects the original folder name "old_zaq".
      abs_old_prefix = "default/" <> String.trim_leading(Path.join(base, "old_zaq"), "/")
      legacy_source = abs_old_prefix <> "/doc.md"

      {:ok, legacy_doc} = Document.create(%{source: legacy_source, content: "stranded"})

      # "zaq" is the CURRENT folder name on disk (it was renamed from "old_zaq" without
      # the fix, leaving the legacy doc stranded).  Now rename "zaq" → "product".
      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      updated = Repo.get!(Document, legacy_doc.id)

      assert updated.source == "default/product/doc.md",
             "Stranded legacy doc must be synced to the new folder name via filesystem check"
    end

    test "fixes doubly-corrupted legacy sources (absolute path embedded twice)" do
      base = Path.expand(@test_base)
      base_without_slash = String.trim_leading(base, "/")

      # A source where the absolute base path was embedded twice by the old
      # broken track_upload running on an already-corrupted source.
      doubly_corrupted =
        "default/" <> base_without_slash <> "/" <> base_without_slash <> "/zaq/doc.md"

      {:ok, corrupted_doc} = Document.create(%{source: doubly_corrupted, content: "corrupt"})

      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      updated = Repo.get!(Document, corrupted_doc.id)

      assert updated.source == "default/product/doc.md",
             "Doubly-corrupted source must be fully unwrapped and rewritten to canonical path"
    end

    test "updates document sources nested two levels deep" do
      File.mkdir_p!(Path.join(@test_base, "zaq/sub"))
      File.write!(Path.join(@test_base, "zaq/sub/deep.md"), "# deep")

      {:ok, nested_doc} =
        Document.create(%{source: "default/zaq/sub/deep.md", content: "# deep"})

      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      assert Document.get_by_source("default/product/sub/deep.md") != nil,
             "Nested doc must be reachable at the renamed path"

      assert Document.get_by_source("default/zaq/sub/deep.md") == nil,
             "Old nested source must not exist after rename"

      assert Repo.get!(Document, nested_doc.id).source == "default/product/sub/deep.md"
    end

    test "list_document_sources after nested rename shows new paths, not old" do
      File.mkdir_p!(Path.join(@test_base, "zaq/sub"))
      File.write!(Path.join(@test_base, "zaq/sub/deep.md"), "# deep")

      {:ok, _} =
        Document.create(%{source: "default/zaq/sub/deep.md", content: "# deep"})

      assert :ok = RenameService.rename_entry("default", "zaq", "product")

      new_results = Ingestion.list_document_sources("product")

      assert Enum.any?(new_results, fn cs -> cs.label == "product" end),
             "New folder 'product' must appear in suggestions after rename"

      old_results = Ingestion.list_document_sources("zaq")

      refute Enum.any?(old_results, fn cs -> cs.label == "zaq" end),
             "Old folder 'zaq' must not appear in suggestions after rename"
    end

    test "leaves filesystem and DB unchanged when rename fails", %{doc: doc} do
      # Renaming to a path whose parent does not exist causes File.rename to
      # return {:error, :enoent}, exercising the failure branch.
      assert {:error, _} = RenameService.rename_entry("default", "zaq", "nonexistent/product")

      # Filesystem: the original directory must still be present.
      assert File.exists?(Path.join(@test_base, "zaq/doc.md"))
      refute File.exists?(Path.join(@test_base, "nonexistent"))

      # DB: all sources must still point to the original paths.
      assert Document.get_by_source("zaq/doc.md") != nil
      assert Document.get_by_source("nonexistent/doc.md") == nil
      assert doc.id == Document.get_by_source("zaq/doc.md").id
    end
  end

  describe "rename_entry/3 for a file" do
    # Line 56 — rename_by_type :file returns :ok immediately when old == new
    # normalize_relative strips "./" so both sides collapse to the same path
    test "returns :ok without touching FS or DB when old and new paths normalise to the same value",
         %{doc: doc} do
      assert :ok = RenameService.rename_entry("default", "zaq/doc.md", "./zaq/doc.md")
      assert Repo.get!(Document, doc.id).source == "zaq/doc.md"
    end

    # Line 244 — build_sidecar_updates nil source_doc clause
    # When the file being renamed has no sidecar pointer in metadata, sidecar_update is nil
    test "renames a plain file with no sidecar successfully" do
      File.write!(Path.join(@test_base, "zaq/plain.txt"), "plain")
      {:ok, plain_doc} = Document.create(%{source: "zaq/plain.txt", content: "plain"})

      assert :ok = RenameService.rename_entry("default", "zaq/plain.txt", "zaq/plain2.txt")

      assert Repo.get!(Document, plain_doc.id).source == "zaq/plain2.txt"
    end

    # Lines 272 + 309 — sidecar metadata present but no sidecar DB record
    # sidecar_doc is nil → sidecar_update.new_metadata = nil (272), maybe_update_document
    # with %{document: nil} is a no-op (309)
    test "renames source file when sidecar DB record is missing" do
      File.write!(Path.join(@test_base, "zaq/orphan.pdf"), "%PDF")
      # Sidecar file exists on disk so FS rename can succeed, but has no Document row
      File.write!(Path.join(@test_base, "zaq/orphan.md"), "# orphan sidecar")

      {:ok, source_doc} =
        Document.create(%{
          source: "zaq/orphan.pdf",
          content: "",
          metadata: Sidecar.source_metadata("zaq/orphan.md")
        })

      assert :ok =
               RenameService.rename_entry("default", "zaq/orphan.pdf", "zaq/orphan_new.pdf")

      assert Repo.get!(Document, source_doc.id).source == "zaq/orphan_new.pdf"
    end
  end

  describe "rename_entry/3 for a directory — legacy sync edge cases" do
    # Line 129 — sync_stranded_legacy_docs returns {:ok, 0} when volume not in volumes map
    # Passing %{} as explicit volumes means Map.get(%{}, "default") == nil -> {:ok, 0}
    test "succeeds with empty volumes map (skips legacy sync)", %{doc: doc} do
      assert :ok = RenameService.rename_entry("default", "zaq", "product2", %{})

      updated = Document.get_by_source("product2/doc.md")
      assert updated != nil
      assert updated.id == doc.id
    end

    # Lines 168 + 176 — migrate_stranded_doc branches
    test "skips stranded legacy doc when matching file is absent from new folder" do
      # Line 168: file doesn't exist under new_relative on disk -> false
      base = Path.expand(@test_base)
      legacy_prefix = "default/" <> String.trim_leading(Path.join(base, "old_folder"), "/")

      {:ok, _legacy} =
        Document.create(%{source: legacy_prefix <> "/absent.md", content: "ghost"})

      # Rename succeeds; the legacy doc is not migrated because no file exists in "zaq"
      assert :ok = RenameService.rename_entry("default", "zaq", "product3")
    end

    test "deduplicates when target source already has a document (upsert collision)" do
      # Line 176: upsert_migrated_doc deletes the stale legacy doc when the
      # canonical target source is already occupied by another document
      base = Path.expand(@test_base)
      old_legacy_prefix = "default/" <> String.trim_leading(Path.join(base, "old_zaq"), "/")

      # File exists on disk under new folder name "zaq" (which we rename to "product4")
      File.write!(Path.join(@test_base, "zaq/doc.md"), "# Hello")

      {:ok, legacy_doc} =
        Document.create(%{source: old_legacy_prefix <> "/doc.md", content: "legacy"})

      # A canonical doc already exists at the target source the migrator would produce
      {:ok, _canonical} =
        Document.create(%{source: "default/product4/doc.md", content: "canonical"})

      assert :ok = RenameService.rename_entry("default", "zaq", "product4")

      # legacy_doc should be deleted (collision resolved by deleting the stale row)
      refute Repo.get(Document, legacy_doc.id)
    end
  end

  describe "rename_entry/3 saga rollback" do
    test "compensates FS rename when DB step fails for a file rename", %{
      source_doc: source_doc,
      sidecar_doc: sidecar_doc
    } do
      # Create a conflicting document at the target source so the DB Multi fails
      # with a unique constraint violation after the FS rename has already run.
      {:ok, _blocker} =
        Document.create(%{source: "zaq/report2.pdf", content: "blocker"})

      File.write!(Path.join(@test_base, "zaq/report2.pdf"), "%PDF-1.0 blocker")

      assert {:error, _} =
               RenameService.rename_entry("default", "zaq/report.pdf", "zaq/report2.pdf")

      # FS compensation must have run: original file is back, target does not
      # exist under the name that would have been produced by the main rename.
      assert File.exists?(Path.join(@test_base, "zaq/report.pdf")),
             "Saga compensation must restore the original file"

      # DB: source rows must still point to old paths.
      assert Repo.get!(Document, source_doc.id).source == "zaq/report.pdf"
      assert Repo.get!(Document, sidecar_doc.id).source == "zaq/report.md"
    end

    test "compensates first FS rename when second FS rename fails (sidecar missing on disk)", %{
      source_doc: source_doc,
      sidecar_doc: sidecar_doc
    } do
      # zaq/report.md is intentionally absent from disk (only in DB).
      # The sidecar rename step will fail with :enoent, triggering compensation
      # of the already-applied main file rename.

      assert {:error, _} =
               RenameService.rename_entry("default", "zaq/report.pdf", "zaq/report_new.pdf")

      # Main FS rename should have been compensated.
      assert File.exists?(Path.join(@test_base, "zaq/report.pdf")),
             "First FS rename must be compensated when the sidecar rename fails"

      refute File.exists?(Path.join(@test_base, "zaq/report_new.pdf"))

      # DB must be untouched.
      assert Repo.get!(Document, source_doc.id).source == "zaq/report.pdf"
      assert Repo.get!(Document, sidecar_doc.id).source == "zaq/report.md"
    end
  end
end
