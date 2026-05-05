defmodule Zaq.Ingestion.RenameServiceTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
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
        document_id: doc.id,
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

      # The document must be findable at the new path after folder rename.
      # This fails today because rename_by_type(:directory) only renames on the
      # filesystem and does not update Document.source in the database.
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

      perm = Repo.get_by(Permission, document_id: updated_doc.id, person_id: person.id)
      assert perm != nil, "Permission should survive the folder rename"
      assert perm.access_rights == ["read"]
    end
  end
end
