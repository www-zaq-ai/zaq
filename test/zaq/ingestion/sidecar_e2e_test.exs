defmodule Zaq.Ingestion.SidecarE2ETest do
  @moduledoc """
  End-to-end tests for sidecar .md detection through the full lifecycle:
  ingestion, file listing, rename, move, and delete.

  Covers the contract:
  - DocumentProcessor creates a sidecar .md DB record with `source_document_source`
    metadata when it ingests a PDF/PPTX/etc. with a pre-existing .md file.
  - DocumentAccess hides sidecar .md files from listings (DB-confirmed only).
  - RenameService keeps the sidecar hidden under its new name after a rename/move.
  - DeleteService removes both the source and its sidecar when the source is deleted.
  """

  use Zaq.DataCase, async: false

  @moduletag :e2e
  @moduletag capture_log: true

  import Mox

  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.KnowledgeBaseOverview
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, DocumentAccess, DocumentProcessor, Sidecar}
  alias Zaq.SystemConfigFixtures

  defmodule PassthroughRouter do
    alias Zaq.Ingestion.DocumentAccess

    def call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [opts]) do
      DocumentAccess.list_files_with_ingestion_status(opts)
    end

    def call(_role, _mod, :broadcast_status, _args), do: :ok
  end

  setup :verify_on_exit!

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})

    tmp =
      Path.join(System.tmp_dir!(), "sidecar_e2e_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: tmp)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(tmp)
    end)

    stub_embedding(1536)
    stub_chunk_title()

    {:ok, tmp: tmp}
  end

  # ---------------------------------------------------------------------------
  # Ingestion → listing
  # ---------------------------------------------------------------------------

  describe "sidecar ingestion → file listing" do
    test "ingested source file hides its sidecar .md from listings", %{tmp: tmp} do
      File.write!("#{tmp}/report.pdf", "pdf-bytes")
      File.write!("#{tmp}/report.md", "# Report\n\nExtracted content.")

      assert {:ok, _doc} = DocumentProcessor.process_single_file("#{tmp}/report.pdf")

      sidecar_doc = Document.get_by_source("report.md")
      assert sidecar_doc != nil
      assert sidecar_doc.metadata["source_document_source"] == "report.pdf"

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert "report.pdf" in sources
      refute "report.md" in sources

      kbo = kbo_sources()
      assert "report.pdf" in kbo
      refute "report.md" in kbo
    end

    test "standalone .md next to a PDF it was NOT ingested from stays visible", %{tmp: tmp} do
      File.write!("#{tmp}/notes.pdf", "pdf-bytes")
      File.write!("#{tmp}/notes.md", "My own notes — not a sidecar.")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert "notes.md" in sources
      assert "notes.md" in kbo_sources()
    end

    test "standalone .md with no companion file stays visible", %{tmp: tmp} do
      File.write!("#{tmp}/standalone.md", "Just a markdown file.")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert "standalone.md" in sources
      assert "standalone.md" in kbo_sources()
    end

    test "sidecar filtering works across all sidecar-producing extensions", %{tmp: tmp} do
      for ext <- ~w(.docx .pptx .xlsx) do
        base = "file#{ext}"
        File.write!("#{tmp}/#{base}", "raw-bytes")
        File.write!("#{tmp}/file.md", "# Extracted\n\nContent from #{ext}.")

        assert {:ok, _} = DocumentProcessor.process_single_file("#{tmp}/#{base}")

        result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
        sources = Enum.map(result, & &1.source)

        assert base in sources, "expected #{base} to be visible"
        refute "file.md" in sources, "expected file.md to be hidden for #{ext}"

        Zaq.Repo.delete_all(Document)
        File.rm!("#{tmp}/#{base}")
        File.rm!("#{tmp}/file.md")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  describe "sidecar + delete" do
    setup %{tmp: tmp} do
      File.write!("#{tmp}/report.pdf", "pdf-bytes")
      File.write!("#{tmp}/report.md", "# Sidecar content")

      {:ok, _} =
        Document.create(%{
          source: "report.pdf",
          content: "",
          metadata: Sidecar.source_metadata("report.md")
        })

      {:ok, _} =
        Document.create(%{
          source: "report.md",
          content: "# Sidecar content",
          metadata: Sidecar.sidecar_metadata("report.pdf")
        })

      :ok
    end

    test "deleting the source file removes both source and sidecar from listings", %{tmp: tmp} do
      assert :ok = Ingestion.delete_path("default", "report.pdf", "file")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      refute "report.pdf" in sources
      refute "report.md" in sources
      refute File.exists?("#{tmp}/report.pdf")
      refute File.exists?("#{tmp}/report.md")

      kbo = kbo_sources()
      refute "report.pdf" in kbo
      refute "report.md" in kbo
    end

    test "sidecar DB record is removed when source is deleted" do
      assert :ok = Ingestion.delete_path("default", "report.pdf", "file")

      assert Document.get_by_source("report.pdf") == nil
      assert Document.get_by_source("report.md") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Rename
  # ---------------------------------------------------------------------------

  describe "sidecar + rename" do
    setup %{tmp: tmp} do
      File.write!("#{tmp}/report.pdf", "pdf-bytes")
      File.write!("#{tmp}/report.md", "# Sidecar content")

      {:ok, _} =
        Document.create(%{
          source: "report.pdf",
          content: "",
          metadata: Sidecar.source_metadata("report.md")
        })

      {:ok, _} =
        Document.create(%{
          source: "report.md",
          content: "# Sidecar content",
          metadata: Sidecar.sidecar_metadata("report.pdf")
        })

      :ok
    end

    test "renaming the source keeps the sidecar hidden under its new name", %{tmp: tmp} do
      assert :ok = Ingestion.rename_entry("default", "report.pdf", "report-v2.pdf")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert "report-v2.pdf" in sources
      refute "report-v2.md" in sources
      assert File.exists?("#{tmp}/report-v2.pdf")
      assert File.exists?("#{tmp}/report-v2.md")

      kbo = kbo_sources()
      assert "report-v2.pdf" in kbo
      refute "report-v2.md" in kbo
    end

    test "original source and sidecar names no longer appear after rename" do
      assert :ok = Ingestion.rename_entry("default", "report.pdf", "report-v2.pdf")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      refute "report.pdf" in sources
      refute "report.md" in sources

      kbo = kbo_sources()
      refute "report.pdf" in kbo
      refute "report.md" in kbo
    end

    test "sidecar DB record is updated to point to new source name after rename" do
      assert :ok = Ingestion.rename_entry("default", "report.pdf", "report-v2.pdf")

      sidecar = Document.get_by_source("report-v2.md")
      assert sidecar != nil
      assert sidecar.metadata["source_document_source"] == "report-v2.pdf"
    end
  end

  # ---------------------------------------------------------------------------
  # Move (rename across directories)
  # ---------------------------------------------------------------------------

  describe "sidecar + move to another folder" do
    setup %{tmp: tmp} do
      File.mkdir_p!("#{tmp}/docs")
      File.mkdir_p!("#{tmp}/archive")
      File.write!("#{tmp}/docs/report.pdf", "pdf-bytes")
      File.write!("#{tmp}/docs/report.md", "# Sidecar content")

      {:ok, _} =
        Document.create(%{
          source: "docs/report.pdf",
          content: "",
          metadata: Sidecar.source_metadata("docs/report.md")
        })

      {:ok, _} =
        Document.create(%{
          source: "docs/report.md",
          content: "# Sidecar content",
          metadata: Sidecar.sidecar_metadata("docs/report.pdf")
        })

      :ok
    end

    test "moving the source keeps the sidecar hidden at the new path", %{tmp: tmp} do
      assert :ok = Ingestion.rename_entry("default", "docs/report.pdf", "archive/report.pdf")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      assert "archive/report.pdf" in sources
      refute "archive/report.md" in sources
      assert File.exists?("#{tmp}/archive/report.pdf")
      assert File.exists?("#{tmp}/archive/report.md")

      kbo = kbo_sources()
      assert "archive/report.pdf" in kbo
      refute "archive/report.md" in kbo
    end

    test "old paths no longer appear after move" do
      assert :ok = Ingestion.rename_entry("default", "docs/report.pdf", "archive/report.pdf")

      result = DocumentAccess.list_files_with_ingestion_status(skip_permissions: true)
      sources = Enum.map(result, & &1.source)

      refute "docs/report.pdf" in sources
      refute "docs/report.md" in sources

      kbo = kbo_sources()
      refute "docs/report.pdf" in kbo
      refute "docs/report.md" in kbo
    end

    test "sidecar DB record reflects the new path and source after move" do
      assert :ok = Ingestion.rename_entry("default", "docs/report.pdf", "archive/report.pdf")

      sidecar = Document.get_by_source("archive/report.md")
      assert sidecar != nil
      assert sidecar.metadata["source_document_source"] == "archive/report.pdf"
    end
  end

  # ---------------------------------------------------------------------------
  # Permission-scoped callers (skip_permissions: false)
  # ---------------------------------------------------------------------------

  describe "sidecar visibility — permission-scoped callers" do
    setup %{tmp: tmp} do
      unique = System.unique_integer([:positive])

      {:ok, person_a} =
        People.create_person(%{
          "full_name" => "Person A #{unique}",
          "email" => "person_a_#{unique}@test.com"
        })

      {:ok, person_b} =
        People.create_person(%{
          "full_name" => "Person B #{unique}",
          "email" => "person_b_#{unique}@test.com"
        })

      {:ok, team_a} = People.create_team(%{name: "Team A #{unique}"})
      {:ok, _} = People.assign_team(person_a, team_a.id)
      {:ok, _} = People.assign_team(person_b, team_a.id)

      File.write!("#{tmp}/report.pdf", "pdf-bytes")
      File.write!("#{tmp}/report.md", "# Sidecar content")

      {:ok, pdf_doc} =
        Document.create(%{
          source: "report.pdf",
          content: "",
          metadata: Sidecar.source_metadata("report.md")
        })

      {:ok, sidecar_doc} =
        Document.create(%{
          source: "report.md",
          content: "# Sidecar content",
          metadata: Sidecar.sidecar_metadata("report.pdf")
        })

      {:ok, _} = Ingestion.set_document_permission(pdf_doc.id, :team, team_a.id, ["read"])

      {:ok, person_a: person_a, person_b: person_b, team_a: team_a, sidecar_doc: sidecar_doc}
    end

    test "person_a (team member) sees PDF but not sidecar via DocumentAccess",
         %{person_a: person_a, team_a: team_a} do
      result =
        DocumentAccess.list_files_with_ingestion_status(
          person_id: person_a.id,
          team_ids: [team_a.id]
        )

      sources = Enum.map(result, & &1.source)
      assert "report.pdf" in sources
      refute "report.md" in sources
    end

    test "person_b (team member) sees PDF but not sidecar via DocumentAccess",
         %{person_b: person_b, team_a: team_a} do
      result =
        DocumentAccess.list_files_with_ingestion_status(
          person_id: person_b.id,
          team_ids: [team_a.id]
        )

      sources = Enum.map(result, & &1.source)
      assert "report.pdf" in sources
      refute "report.md" in sources
    end

    test "sidecar stays hidden even when it has an explicit permission row",
         %{person_a: person_a, team_a: team_a, sidecar_doc: sidecar_doc} do
      # source_document_source IS NULL filter in the DB query means the sidecar
      # is excluded regardless of whether it has a matching permission row.
      {:ok, _} = Ingestion.set_document_permission(sidecar_doc.id, :team, team_a.id, ["read"])

      result =
        DocumentAccess.list_files_with_ingestion_status(
          person_id: person_a.id,
          team_ids: [team_a.id]
        )

      refute "report.md" in Enum.map(result, & &1.source)
    end

    test "person with no permissions sees neither PDF nor sidecar" do
      unique = System.unique_integer([:positive])

      {:ok, outsider} =
        People.create_person(%{
          "full_name" => "Outsider #{unique}",
          "email" => "outsider_#{unique}@test.com"
        })

      result =
        DocumentAccess.list_files_with_ingestion_status(
          person_id: outsider.id,
          team_ids: []
        )

      sources = Enum.map(result, & &1.source)
      refute "report.pdf" in sources
      refute "report.md" in sources
    end

    test "KBO: person_a sees PDF but not sidecar through the agent tool",
         %{person_a: person_a, team_a: team_a} do
      ctx = %{
        status_context: nil,
        node_router: PassthroughRouter,
        person_id: person_a.id,
        team_ids: [team_a.id],
        skip_permissions: false
      }

      {:ok, result} = KnowledgeBaseOverview.run(%{}, ctx)
      sources = Enum.map(result.documents, & &1.source)
      assert "report.pdf" in sources
      refute "report.md" in sources
    end

    test "KBO: person_b sees PDF but not sidecar through the agent tool",
         %{person_b: person_b, team_a: team_a} do
      ctx = %{
        status_context: nil,
        node_router: PassthroughRouter,
        person_id: person_b.id,
        team_ids: [team_a.id],
        skip_permissions: false
      }

      {:ok, result} = KnowledgeBaseOverview.run(%{}, ctx)
      sources = Enum.map(result.documents, & &1.source)
      assert "report.pdf" in sources
      refute "report.md" in sources
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp kbo_sources do
    {:ok, result} =
      KnowledgeBaseOverview.run(%{}, %{
        status_context: nil,
        node_router: PassthroughRouter,
        skip_permissions: true
      })

    Enum.map(result.documents, & &1.source)
  end

  defp stub_embedding(dim) do
    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      body = Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, dim)}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp stub_chunk_title do
    Zaq.Agent.ChunkTitleMock
    |> stub(:ask, fn _content, _opts -> {:ok, "Title"} end)
  end
end
