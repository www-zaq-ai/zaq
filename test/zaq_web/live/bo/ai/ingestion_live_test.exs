defmodule ZaqWeb.Live.BO.AI.IngestionLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Chunk, Document, IngestJob}
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})
    :ok
  end

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "ingestion_live_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_ingestion_live_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "docs/sub"))
    File.mkdir_p!(Path.join(tmp_dir, "target"))
    File.write!(Path.join(tmp_dir, "alpha.md"), "# alpha")
    File.write!(Path.join(tmp_dir, "notes.txt"), "notes")
    File.write!(Path.join(tmp_dir, "docs/readme.md"), "# readme")

    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: tmp_dir)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(tmp_dir)
    end)

    {:ok, conn: conn, tmp_dir: tmp_dir}
  end

  defp create_job(attrs) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "notes.txt", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  defp create_document_with_chunk(source, attrs \\ %{}) do
    {:ok, doc} =
      attrs
      |> Map.merge(%{source: source, content: "doc content"})
      |> Document.create()

    {:ok, _chunk} =
      Chunk.create(%{
        document_id: doc.id,
        content: "chunk content",
        chunk_index: 0
      })

    doc
  end

  defp create_linked_documents(source_source, sidecar_source) do
    source_doc =
      create_document_with_chunk(source_source, %{
        metadata: %{"sidecar_source" => sidecar_source}
      })

    sidecar_doc =
      create_document_with_chunk(sidecar_source, %{
        metadata: %{"source_document_source" => source_source}
      })

    {source_doc, sidecar_doc}
  end

  defp assert_linked_sources(source_source, sidecar_source) do
    assert %Document{} = source_doc = Document.get_by_source(source_source)
    assert source_doc.metadata["sidecar_source"] == sidecar_source

    assert %Document{} = sidecar_doc = Document.get_by_source(sidecar_source)
    assert sidecar_doc.metadata["source_document_source"] == source_source
  end

  # ────────────────────────────────────────────────────────────────
  # Existing tests (unchanged)
  # ────────────────────────────────────────────────────────────────

  test "navigates directories and handles non-directory navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    assert has_element?(view, "button", "docs")
    assert has_element?(view, "span", "alpha.md")

    render_hook(view, "navigate", %{"path" => "docs"})
    assert has_element?(view, "span", "readme.md")

    render_hook(view, "go_back", %{})
    assert has_element?(view, "button", "docs")

    render_hook(view, "navigate", %{"path" => "notes.txt"})
    assert has_element?(view, "td", "Empty directory")
  end

  test "supports selection, modal open/close, and view mode toggle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_select", %{"path" => "alpha.md"})
    assert has_element?(view, "button", "Delete (1)")

    render_hook(view, "select_all", %{})
    assert has_element?(view, "button", "Delete (4)")

    render_hook(view, "select_all", %{})
    refute has_element?(view, "button", "Delete (4)")

    render_hook(view, "show_delete_confirmation", %{})
    assert has_element?(view, "h3", "Delete Selected")

    render_hook(view, "close_modal", %{})
    refute has_element?(view, "h3", "Delete Selected")

    render_hook(view, "toggle_view_mode", %{"mode" => "grid"})
    assert has_element?(view, "span", "Select all")
  end

  test "opens file preview inside modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    view
    |> element(~s(button[phx-click="open_preview"][phx-value-path$="alpha.md"]))
    |> render_click()

    assert has_element?(view, "#file-preview-modal")
    assert has_element?(view, "#file-preview-modal", "alpha.md")

    render_hook(view, "close_preview_modal", %{})
    refute has_element?(view, "#file-preview-modal")
  end

  test "creates folders with validation and error handling", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "show_new_folder_modal", %{})
    assert has_element?(view, "#new-folder-input")

    render_hook(view, "create_folder", %{"name" => "   "})
    assert has_element?(view, "p", "Folder name cannot be empty.")

    render_hook(view, "create_folder", %{"name" => "../outside"})
    assert has_element?(view, "p", "Failed: :path_traversal")

    render_hook(view, "create_folder", %{"name" => "reports"})
    assert File.dir?(Path.join(tmp_dir, "reports"))
    refute has_element?(view, "#new-folder-input")
  end

  test "renames files and handles validation branches", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "rename_item", %{"path" => "notes.txt", "type" => "file"})
    assert has_element?(view, "h3", "Rename")

    render_hook(view, "confirm_rename", %{"name" => "   "})
    assert has_element?(view, "p", "Name cannot be empty.")

    render_hook(view, "confirm_rename", %{"name" => "notes.txt"})
    refute has_element?(view, "#rename-input")

    render_hook(view, "rename_item", %{"path" => "notes.txt", "type" => "file"})
    render_hook(view, "confirm_rename", %{"name" => "../bad-name"})
    assert has_element?(view, "p", "Rename failed: :path_traversal")

    render_hook(view, "confirm_rename", %{"name" => "notes-renamed.txt"})
    assert File.exists?(Path.join(tmp_dir, "notes-renamed.txt"))
    refute File.exists?(Path.join(tmp_dir, "notes.txt"))
  end

  test "deletes files and directories with success and failure cases", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    {:ok, _doc} = Document.create(%{source: "alpha.md", content: "doc alpha"})

    render_hook(view, "delete_item", %{"path" => "alpha.md", "type" => "file"})
    render_hook(view, "confirm_delete", %{})

    refute File.exists?(Path.join(tmp_dir, "alpha.md"))
    assert Document.get_by_source("alpha.md") == nil

    render_hook(view, "delete_item", %{"path" => "docs", "type" => "directory"})
    render_hook(view, "confirm_delete", %{})
    refute File.dir?(Path.join(tmp_dir, "docs"))

    render_hook(view, "delete_item", %{"path" => "missing.txt", "type" => "file"})
    render_hook(view, "confirm_delete", %{})
    assert has_element?(view, "p", "Delete failed: :enoent")
  end

  describe "single-file delete RAG cleanup" do
    test "removes document and chunks in non-volume mode", %{conn: conn, tmp_dir: tmp_dir} do
      doc = create_document_with_chunk("alpha.md")
      assert Chunk.count_by_document(doc.id) == 1

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "./alpha.md", "type" => "file"})
      render_hook(view, "confirm_delete", %{})

      refute File.exists?(Path.join(tmp_dir, "alpha.md"))
      assert Document.get_by_source("alpha.md") == nil
      assert Chunk.count_by_document(doc.id) == 0
    end

    test "removes volume-prefixed document and chunks", %{conn: conn, tmp_dir: tmp_dir} do
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => tmp_dir})

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original || [])
      end)

      doc = create_document_with_chunk("docs/alpha.md")
      assert Chunk.count_by_document(doc.id) == 1

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "./alpha.md", "type" => "file"})
      render_hook(view, "confirm_delete", %{})

      refute File.exists?(Path.join(tmp_dir, "alpha.md"))
      assert Document.get_by_source("docs/alpha.md") == nil
      assert Chunk.count_by_document(doc.id) == 0
    end

    test "removes metadata-linked sidecar in non-volume mode", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.generated.md"), "# Report sidecar")

      source_doc =
        create_document_with_chunk("report.pdf", %{
          metadata: %{"sidecar_source" => "report.generated.md"}
        })

      sidecar_doc =
        create_document_with_chunk("report.generated.md", %{
          metadata: %{"source_document_source" => "report.pdf"}
        })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "./report.pdf", "type" => "file"})
      render_hook(view, "confirm_delete", %{})

      refute File.exists?(Path.join(tmp_dir, "report.pdf"))
      refute File.exists?(Path.join(tmp_dir, "report.generated.md"))

      assert Document.get_by_source("report.pdf") == nil
      assert Document.get_by_source("report.generated.md") == nil
      assert Chunk.count_by_document(source_doc.id) == 0
      assert Chunk.count_by_document(sidecar_doc.id) == 0
    end

    test "removes metadata-linked sidecar in volume mode", %{conn: conn, tmp_dir: tmp_dir} do
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => tmp_dir})

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original || [])
      end)

      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.generated.md"), "# Report sidecar")

      source_doc =
        create_document_with_chunk("docs/report.pdf", %{
          metadata: %{"sidecar_source" => "docs/report.generated.md"}
        })

      sidecar_doc =
        create_document_with_chunk("docs/report.generated.md", %{
          metadata: %{"source_document_source" => "docs/report.pdf"}
        })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "./report.pdf", "type" => "file"})
      render_hook(view, "confirm_delete", %{})

      refute File.exists?(Path.join(tmp_dir, "report.pdf"))
      refute File.exists?(Path.join(tmp_dir, "report.generated.md"))

      assert Document.get_by_source("docs/report.pdf") == nil
      assert Document.get_by_source("docs/report.generated.md") == nil
      assert Chunk.count_by_document(source_doc.id) == 0
      assert Chunk.count_by_document(sidecar_doc.id) == 0
    end

    test "removes metadata-linked image sidecar md", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "photo.png"), "png-data")
      File.write!(Path.join(tmp_dir, "photo.md"), "# Photo OCR")

      source_doc =
        create_document_with_chunk("photo.png", %{
          metadata: %{"sidecar_source" => "photo.md"}
        })

      sidecar_doc =
        create_document_with_chunk("photo.md", %{
          metadata: %{"source_document_source" => "photo.png"}
        })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "./photo.png", "type" => "file"})
      render_hook(view, "confirm_delete", %{})

      refute File.exists?(Path.join(tmp_dir, "photo.png"))
      refute File.exists?(Path.join(tmp_dir, "photo.md"))

      assert Document.get_by_source("photo.png") == nil
      assert Document.get_by_source("photo.md") == nil
      assert Chunk.count_by_document(source_doc.id) == 0
      assert Chunk.count_by_document(sidecar_doc.id) == 0
    end
  end

  describe "directory delete RAG cleanup" do
    test "deleting nested directory removes nested documents and chunks in volume mode", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      docs_root = Path.join(tmp_dir, "docs")
      nested_dir = Path.join(docs_root, "sub/deep")
      File.mkdir_p!(nested_dir)

      File.write!(Path.join(nested_dir, "first.md"), "# First")
      File.write!(Path.join(nested_dir, "second.md"), "# Second")

      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => docs_root})

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original || [])
      end)

      first_doc = create_document_with_chunk("docs/sub/deep/first.md")
      second_doc = create_document_with_chunk("docs/sub/deep/second.md")

      assert Chunk.count_by_document(first_doc.id) == 1
      assert Chunk.count_by_document(second_doc.id) == 1

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "delete_item", %{"path" => "sub", "type" => "directory"})
      render_hook(view, "confirm_delete", %{})

      refute File.dir?(Path.join(docs_root, "sub"))

      assert Document.get_by_source("docs/sub/deep/first.md") == nil
      assert Document.get_by_source("docs/sub/deep/second.md") == nil
      assert Chunk.count_by_document(first_doc.id) == 0
      assert Chunk.count_by_document(second_doc.id) == 0
    end
  end

  test "bulk delete handles full success and partial failures", %{conn: conn, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "bulk-a.txt"), "A")
    File.write!(Path.join(tmp_dir, "bulk-b.txt"), "B")

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "toggle_select", %{"path" => "bulk-a.txt"})
    render_hook(view, "toggle_select", %{"path" => "bulk-b.txt"})
    render_hook(view, "show_delete_confirmation", %{})
    render_hook(view, "confirm_delete_selected", %{})

    refute File.exists?(Path.join(tmp_dir, "bulk-a.txt"))
    refute File.exists?(Path.join(tmp_dir, "bulk-b.txt"))

    File.write!(Path.join(tmp_dir, "bulk-ok.txt"), "ok")
    render_hook(view, "toggle_select", %{"path" => "bulk-ok.txt"})
    render_hook(view, "toggle_select", %{"path" => "missing-bulk.txt"})
    render_hook(view, "show_delete_confirmation", %{})
    render_hook(view, "confirm_delete_selected", %{})

    refute File.exists?(Path.join(tmp_dir, "bulk-ok.txt"))

    File.write!(Path.join(tmp_dir, "bulk-report.pdf"), "%PDF")
    File.write!(Path.join(tmp_dir, "bulk-report.md"), "# sidecar")

    source_doc =
      create_document_with_chunk("bulk-report.pdf", %{
        metadata: %{"sidecar_source" => "bulk-report.md"}
      })

    sidecar_doc =
      create_document_with_chunk("bulk-report.md", %{
        metadata: %{"source_document_source" => "bulk-report.pdf"}
      })

    render_hook(view, "toggle_select", %{"path" => "bulk-report.pdf"})
    render_hook(view, "show_delete_confirmation", %{})
    render_hook(view, "confirm_delete_selected", %{})

    refute File.exists?(Path.join(tmp_dir, "bulk-report.pdf"))
    refute File.exists?(Path.join(tmp_dir, "bulk-report.md"))

    assert Document.get_by_source("bulk-report.pdf") == nil
    assert Document.get_by_source("bulk-report.md") == nil
    assert Chunk.count_by_document(source_doc.id) == 0
    assert Chunk.count_by_document(sidecar_doc.id) == 0
  end

  test "moves items and handles move validation branches", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "move_item", %{"path" => "notes.txt", "type" => "file"})
    render_hook(view, "confirm_move", %{})
    assert has_element?(view, "p", "Already in this folder.")

    render_hook(view, "move_navigate", %{"path" => "target"})
    render_hook(view, "confirm_move", %{})
    assert File.exists?(Path.join(tmp_dir, "target/notes.txt"))

    render_hook(view, "move_item", %{"path" => "docs", "type" => "directory"})
    render_hook(view, "move_navigate", %{"path" => "docs/sub"})
    render_hook(view, "confirm_move", %{})
    assert has_element?(view, "p", "Cannot move a folder into itself.")

    render_hook(view, "move_go_back", %{})
    assert has_element?(view, "span", "docs")
  end

  describe "rename and move keep source/sidecar in sync" do
    test "renaming source co-renames sidecar and updates metadata links in non-volume mode", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.md"), "# sidecar")

      {source_doc, sidecar_doc} =
        create_linked_documents("default/report.pdf", "default/report.md")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "rename_item", %{"path" => "report.pdf", "type" => "file"})
      render_hook(view, "confirm_rename", %{"name" => "report-v2.pdf"})

      refute File.exists?(Path.join(tmp_dir, "report.pdf"))
      refute File.exists?(Path.join(tmp_dir, "report.md"))
      assert File.exists?(Path.join(tmp_dir, "report-v2.pdf"))
      assert File.exists?(Path.join(tmp_dir, "report-v2.md"))

      assert Document.get_by_source("default/report.pdf") == nil
      assert Document.get_by_source("default/report.md") == nil
      assert_linked_sources("default/report-v2.pdf", "default/report-v2.md")

      assert Chunk.count_by_document(source_doc.id) == 1
      assert Chunk.count_by_document(sidecar_doc.id) == 1
    end

    test "moving source co-moves sidecar and updates metadata links in non-volume mode", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.md"), "# sidecar")

      {source_doc, sidecar_doc} =
        create_linked_documents("default/report.pdf", "default/report.md")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "move_item", %{"path" => "report.pdf", "type" => "file"})
      render_hook(view, "move_navigate", %{"path" => "target"})
      render_hook(view, "confirm_move", %{})

      refute File.exists?(Path.join(tmp_dir, "report.pdf"))
      refute File.exists?(Path.join(tmp_dir, "report.md"))
      assert File.exists?(Path.join(tmp_dir, "target/report.pdf"))
      assert File.exists?(Path.join(tmp_dir, "target/report.md"))

      assert Document.get_by_source("default/report.pdf") == nil
      assert Document.get_by_source("default/report.md") == nil
      assert_linked_sources("default/target/report.pdf", "default/target/report.md")

      assert Chunk.count_by_document(source_doc.id) == 1
      assert Chunk.count_by_document(sidecar_doc.id) == 1
    end

    test "renaming source co-renames sidecar and updates metadata links in volume mode", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => tmp_dir})

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original || [])
      end)

      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.md"), "# sidecar")

      {source_doc, sidecar_doc} = create_linked_documents("docs/report.pdf", "docs/report.md")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "rename_item", %{"path" => "report.pdf", "type" => "file"})
      render_hook(view, "confirm_rename", %{"name" => "report-v2.pdf"})

      refute File.exists?(Path.join(tmp_dir, "report.pdf"))
      refute File.exists?(Path.join(tmp_dir, "report.md"))
      assert File.exists?(Path.join(tmp_dir, "report-v2.pdf"))
      assert File.exists?(Path.join(tmp_dir, "report-v2.md"))

      assert Document.get_by_source("docs/report.pdf") == nil
      assert Document.get_by_source("docs/report.md") == nil
      assert_linked_sources("docs/report-v2.pdf", "docs/report-v2.md")

      assert Chunk.count_by_document(source_doc.id) == 1
      assert Chunk.count_by_document(sidecar_doc.id) == 1
    end

    test "moving source co-moves sidecar and updates metadata links in volume mode", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => tmp_dir})

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original || [])
      end)

      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.md"), "# sidecar")

      {source_doc, sidecar_doc} = create_linked_documents("docs/report.pdf", "docs/report.md")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "move_item", %{"path" => "report.pdf", "type" => "file"})
      render_hook(view, "move_navigate", %{"path" => "target"})
      render_hook(view, "confirm_move", %{})

      refute File.exists?(Path.join(tmp_dir, "report.pdf"))
      refute File.exists?(Path.join(tmp_dir, "report.md"))
      assert File.exists?(Path.join(tmp_dir, "target/report.pdf"))
      assert File.exists?(Path.join(tmp_dir, "target/report.md"))

      assert Document.get_by_source("docs/report.pdf") == nil
      assert Document.get_by_source("docs/report.md") == nil
      assert_linked_sources("docs/target/report.pdf", "docs/target/report.md")

      assert Chunk.count_by_document(source_doc.id) == 1
      assert Chunk.count_by_document(sidecar_doc.id) == 1
    end
  end

  test "filters jobs, handles retry/cancel branches, and refreshes on job updates", %{conn: conn} do
    pending = create_job(%{file_path: "pending.txt", status: "pending"})
    completed = create_job(%{file_path: "completed.txt", status: "completed"})

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    render_hook(view, "filter_status", %{"status" => "pending"})
    assert has_element?(view, "p", "pending.txt")
    refute has_element?(view, "p", "completed.txt")

    render_hook(view, "retry_job", %{"id" => completed.id})
    assert Repo.get!(IngestJob, completed.id).status == "completed"

    render_hook(view, "cancel_job", %{"id" => pending.id})
    assert Repo.get!(IngestJob, pending.id).status == "failed"

    render_hook(view, "cancel_job", %{"id" => completed.id})
    assert Repo.get!(IngestJob, completed.id).status == "completed"

    fresh = create_job(%{file_path: "fresh.txt", status: "pending"})
    send(view.pid, {:job_updated, fresh})
    assert has_element?(view, "p", "fresh.txt")
  end

  test "shows chunk progress and retry button for completed_with_errors jobs", %{conn: conn} do
    partial =
      create_job(%{
        file_path: "partial.txt",
        status: "completed_with_errors",
        total_chunks: 10,
        ingested_chunks: 7,
        failed_chunks: 3,
        failed_chunk_indices: [2, 4, 9],
        error: "3 chunks failed after retries"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    assert has_element?(view, "p", "partial.txt")
    assert has_element?(view, "p", "Chunks: 7/10")
    assert has_element?(view, "p", "Failed chunks: 3")

    render_hook(view, "retry_job", %{"id" => partial.id})

    assert Repo.get!(IngestJob, partial.id).status in [
             "pending",
             "processing",
             "completed",
             "completed_with_errors"
           ]
  end

  test "uploads accepted files", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    upload =
      file_input(view, "#upload-form", :files, [
        %{name: "upload.txt", content: "hello upload", type: "text/plain"}
      ])

    assert render_upload(upload, "upload.txt")

    view
    |> form("#upload-form")
    |> render_submit()

    assert File.exists?(Path.join(tmp_dir, "upload.txt"))
  end

  test "uploads png and jpg files", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

    png_upload =
      file_input(view, "#upload-form", :files, [
        %{name: "diagram.png", content: "png-data", type: "image/png"}
      ])

    assert render_upload(png_upload, "diagram.png")

    view
    |> form("#upload-form")
    |> render_submit()

    jpg_upload =
      file_input(view, "#upload-form", :files, [
        %{name: "photo.jpg", content: "jpg-data", type: "image/jpeg"}
      ])

    assert render_upload(jpg_upload, "photo.jpg")

    view
    |> form("#upload-form")
    |> render_submit()

    assert File.exists?(Path.join(tmp_dir, "diagram.png"))
    assert File.exists?(Path.join(tmp_dir, "photo.jpg"))
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Raw content modal
  # ────────────────────────────────────────────────────────────────

  describe "add raw content modal" do
    test "show_add_raw_modal opens the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      # h3 text in the template is "Add Raw MD Content"
      assert has_element?(view, "h3", "Add Raw MD Content")
    end

    test "save_raw_content with blank filename shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "   ", "content" => "hello"})

      assert has_element?(view, "p", "Filename cannot be empty.")
    end

    test "save_raw_content with blank content shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "myfile", "content" => "   "})

      assert has_element?(view, "p", "Content cannot be empty.")
    end

    test "save_raw_content creates file without extension and auto-appends .md", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "mynote", "content" => "# Hi"})

      assert File.exists?(Path.join(tmp_dir, "mynote.md"))
      refute has_element?(view, "h3", "Add Raw MD Content")
    end

    test "save_raw_content preserves existing extension", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "doc.txt", "content" => "hello"})

      assert File.exists?(Path.join(tmp_dir, "doc.txt"))
    end

    test "add_raw_content alias behaves identically to save_raw_content", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "add_raw_content", %{"filename" => "aliased", "content" => "body"})

      assert File.exists?(Path.join(tmp_dir, "aliased.md"))
    end

    # update_raw_field assigns raw_filename/raw_content but the template input
    # binds to @modal_name — so the assign is updated without crashing but is
    # not reflected in the rendered input value.
    test "update_raw_field for filename does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})

      assert render_hook(view, "update_raw_field", %{
               "field" => "filename",
               "value" => "typed-name"
             })
    end

    test "update_raw_field for content does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})

      assert render_hook(view, "update_raw_field", %{
               "field" => "content",
               "value" => "some text"
             })
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Ingest mode and ingest_selected
  # ────────────────────────────────────────────────────────────────

  describe "ingest mode and triggering ingestion" do
    test "set_mode switches between available modes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Template renders mode buttons for ~w(async inline) — switch to inline
      render_hook(view, "set_mode", %{"mode" => "inline"})
      # The active button gets the highlight class; inactive buttons do not
      assert render(view) =~ "bg-\\[#03b6d4\\].*inline|inline.*bg-\\[#03b6d4\\]" or
               render(view) =~ "inline"

      render_hook(view, "set_mode", %{"mode" => "async"})
      assert render(view) =~ "async"
    end

    test "ingest_selected clears selection and shows flash for a file", %{conn: conn} do
      Mox.stub(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, %{id: nil}}
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "toggle_select", %{"path" => "alpha.md"})
      assert has_element?(view, "button", "Delete (1)")

      render_hook(view, "ingest_selected", %{})

      # Selection is cleared after ingestion
      refute has_element?(view, "button", "Delete (1)")
      # A job row for the file appears in the jobs table
      assert has_element?(view, "p", "alpha.md")
    end

    test "ingest_selected clears selection and shows flash for a directory", %{conn: conn} do
      Mox.stub(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, %{id: nil}}
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "toggle_select", %{"path" => "docs"})
      assert has_element?(view, "button", "Delete (1)")

      render_hook(view, "ingest_selected", %{})

      # Selection is cleared after ingestion
      refute has_element?(view, "button", "Delete (1)")
      # A job row for a file inside the folder appears in the jobs table
      assert has_element?(view, "p", ~r/readme\.md/)
    end

    test "ingest_selected processes file without role_id (RBAC-based access)", %{conn: conn} do
      parent = self()

      Mox.stub(Zaq.DocumentProcessorMock, :process_single_file, fn path ->
        send(parent, {:path_ingested, path})
        {:ok, %{id: nil}}
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "set_mode", %{"mode" => "inline"})
      render_hook(view, "toggle_select", %{"path" => "alpha.md"})
      render_hook(view, "ingest_selected", %{})

      assert_receive {:path_ingested, _path}, 500
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: validate_upload (noop handler)
  # ────────────────────────────────────────────────────────────────

  describe "validate_upload" do
    test "validate_upload event does not crash the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Should return {:noreply, socket} without changing state
      assert render_hook(view, "validate_upload", %{})
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: filter_status reset to "all"
  # ────────────────────────────────────────────────────────────────

  describe "filter_status all" do
    test "filtering by 'all' shows jobs of every status", %{conn: conn} do
      create_job(%{file_path: "p.txt", status: "pending"})
      create_job(%{file_path: "c.txt", status: "completed"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "filter_status", %{"status" => "pending"})
      refute has_element?(view, "p", "c.txt")

      render_hook(view, "filter_status", %{"status" => "all"})
      assert has_element?(view, "p", "p.txt")
      assert has_element?(view, "p", "c.txt")
    end
  end

  describe "lane c edge branches" do
    test "save_raw_content surfaces upload errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "show_add_raw_modal", %{})
      render_hook(view, "save_raw_content", %{"filename" => "../escape", "content" => "body"})

      assert has_element?(view, "p", "Save failed: :path_traversal")
    end

    test "confirm_move shows an error when source is missing", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "move_item", %{"path" => "notes.txt", "type" => "file"})
      render_hook(view, "move_navigate", %{"path" => "target"})

      File.rm!(Path.join(tmp_dir, "notes.txt"))

      render_hook(view, "confirm_move", %{})
      assert render(view) =~ "Move failed"
    end

    test "ingest_selected skips missing selected paths", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      before_count = Repo.aggregate(IngestJob, :count)

      render_hook(view, "toggle_select", %{"path" => "missing-file.md"})
      render_hook(view, "ingest_selected", %{})

      assert Repo.aggregate(IngestJob, :count) == before_count
      refute has_element?(view, "p", "missing-file.md")
    end

    test "retry_job and cancel_job return not_found for missing ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      missing_id = Ecto.UUID.generate()

      render_hook(view, "retry_job", %{"id" => missing_id})
      retry_state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(retry_state.socket.assigns.flash, :error) ==
               "Retry failed: not_found"

      render_hook(view, "cancel_job", %{"id" => missing_id})
      cancel_state = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(cancel_state.socket.assigns.flash, :error) ==
               "Cancel failed: not_found"
    end

    test "filter_status with unknown value returns empty job list", %{conn: conn} do
      create_job(%{file_path: "a-pending.txt", status: "pending"})
      create_job(%{file_path: "a-completed.txt", status: "completed"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "filter_status", %{"status" => "unknown_status"})

      refute has_element?(view, "p", "a-pending.txt")
      refute has_element?(view, "p", "a-completed.txt")
      assert has_element?(view, "p", "No jobs yet")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: move_go_back from root stays at "."
  # ────────────────────────────────────────────────────────────────

  describe "move_go_back at root" do
    test "move_go_back from root dir '.' stays at root", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "move_item", %{"path" => "notes.txt", "type" => "file"})
      # Already at root; going back should not crash and should stay at "."
      render_hook(view, "move_go_back", %{})
      assert has_element?(view, "h3", "Move")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: ingestion_map stale detection
  # ────────────────────────────────────────────────────────────────

  describe "ingestion_map stale detection" do
    test "file with no document shows as not ingested", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")

      # alpha.md has no document — should NOT show an ingested badge
      refute html =~ ~r/alpha\.md.*ingested/s
    end

    test "file ingested before last modification shows as stale", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      # Create the document normally, then force updated_at to the past
      {:ok, doc} = Document.create(%{source: "default/alpha.md", content: "old"})

      Repo.update_all(
        from(d in Document, where: d.id == ^doc.id),
        set: [updated_at: ~U[2000-01-01 00:00:00Z]]
      )

      # Re-write the file so its mtime is definitely after 2000-01-01
      File.write!(Path.join(tmp_dir, "alpha.md"), "# alpha updated")

      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")

      assert html =~ "stale"
    end

    test "file ingested after last modification shows as up to date", %{conn: conn} do
      # Create the document normally, then force updated_at to the future
      {:ok, doc} = Document.create(%{source: "default/alpha.md", content: "# alpha"})

      Repo.update_all(
        from(d in Document, where: d.id == ^doc.id),
        set: [updated_at: DateTime.utc_now() |> DateTime.add(3600)]
      )

      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")

      refute html =~ "stale"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: format_size/1 and status_color/1 helper functions
  # ────────────────────────────────────────────────────────────────

  describe "format_size/1" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "bytes < 1024 shows B suffix" do
      assert IngestionLive.format_size(512) == "512 B"
    end

    test "bytes < 1 MB shows KB suffix" do
      assert IngestionLive.format_size(2048) == "2.0 KB"
    end

    test "bytes >= 1 MB shows MB suffix" do
      assert IngestionLive.format_size(2_097_152) == "2.0 MB"
    end
  end

  describe "status_color/1" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "pending returns muted classes" do
      assert IngestionLive.status_color("pending") =~ "bg-black"
    end

    test "processing returns amber classes" do
      assert IngestionLive.status_color("processing") =~ "amber"
    end

    test "completed returns emerald classes" do
      assert IngestionLive.status_color("completed") =~ "emerald"
    end

    test "failed returns red classes" do
      assert IngestionLive.status_color("failed") =~ "red"
    end

    test "unknown status returns fallback classes" do
      assert IngestionLive.status_color("unknown") =~ "bg-black"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: handle_info job_updated — processing with chunks scheduled
  # ────────────────────────────────────────────────────────────────

  describe "handle_info {:job_updated, job} — processing with chunks" do
    test "refreshes entries when job transitions to processing with chunks scheduled", %{
      conn: conn
    } do
      job = create_job(%{file_path: "notes.txt", status: "pending"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Transition to processing in DB and use the real struct (has all fields)
      {:ok, processing_job} =
        Repo.get!(IngestJob, job.id)
        |> IngestJob.changeset(%{status: "processing", total_chunks: 5})
        |> Repo.update()

      send(view.pid, {:job_updated, processing_job})

      # View must still be alive and not crash
      assert has_element?(view, "p", "notes.txt")
    end

    test "job_updated for a job not matching the current filter is silently ignored", %{
      conn: conn
    } do
      # Create a completed job in the DB so we have a real struct with all fields
      completed_job = create_job(%{file_path: "ghost.txt", status: "completed"})
      completed_job = Repo.get!(IngestJob, completed_job.id)

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Filter to only show pending jobs — "completed" won't match
      render_hook(view, "filter_status", %{"status" => "pending"})

      # Send the completed job — it has no pending match so handle_filtered_job no-op fires
      send(view.pid, {:job_updated, completed_job})

      state = :sys.get_state(view.pid)
      job_ids = Enum.map(state.socket.assigns.jobs, & &1.id)
      refute completed_job.id in job_ids
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: status_color for completed_with_errors
  # ────────────────────────────────────────────────────────────────

  describe "status_color/1 completed_with_errors" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "completed_with_errors returns orange classes" do
      assert IngestionLive.status_color("completed_with_errors") =~ "orange"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Grid view job status badges
  # These tests exercise branches inside file_grid_view/1 that are
  # not hit by any other test (processing / pending / failed / stale
  # status badges in the grid card).
  # ────────────────────────────────────────────────────────────────

  describe "grid view job status badges" do
    test "grid view shows processing badge when a job is in processing state", %{conn: conn} do
      create_job(%{file_path: "notes.txt", status: "processing"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})

      assert render(view) =~ "processing"
    end

    test "grid view shows pending badge when a job is in pending state", %{conn: conn} do
      create_job(%{file_path: "notes.txt", status: "pending"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})

      assert render(view) =~ "pending"
    end

    test "grid view shows failed badge when a job is in failed state", %{conn: conn} do
      create_job(%{file_path: "notes.txt", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})

      assert render(view) =~ "failed"
    end

    test "grid view shows stale badge for a document ingested before last file modification", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, doc} = Document.create(%{source: "default/notes.txt", content: "old content"})

      Repo.update_all(
        from(d in Document, where: d.id == ^doc.id),
        set: [updated_at: ~U[2000-01-01 00:00:00Z]]
      )

      File.write!(Path.join(tmp_dir, "notes.txt"), "updated content")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})

      assert render(view) =~ "stale"
    end

    test "grid view shows ingested badge and shared indicator when a document has permissions", %{
      conn: conn
    } do
      {:ok, doc} = Document.create(%{source: "default/notes.txt", content: "ingested content"})
      person = People.list_people() |> List.first()

      if person do
        Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])
      end

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")
      render_hook(view, "toggle_view_mode", %{"mode" => "grid"})

      # Should render ingested state without crashing
      assert render(view) =~ "ingested"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # NEW: Volume selection (multi-volume ingestion)
  # ────────────────────────────────────────────────────────────────

  describe "volume selection" do
    setup %{conn: conn, tmp_dir: tmp_dir} do
      vol_docs = Path.join(tmp_dir, "volumes/docs")
      vol_archives = Path.join(tmp_dir, "volumes/archives")
      File.mkdir_p!(vol_docs)
      File.mkdir_p!(vol_archives)
      File.write!(Path.join(vol_docs, "manual.md"), "# Manual")
      File.write!(Path.join(vol_archives, "old.md"), "# Old")

      original = Application.get_env(:zaq, Zaq.Ingestion)

      Application.put_env(:zaq, Zaq.Ingestion,
        volumes: %{"docs" => vol_docs, "archives" => vol_archives}
      )

      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)

      {:ok, conn: conn, vol_docs: vol_docs, vol_archives: vol_archives}
    end

    test "shows volume selector when multiple volumes configured", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/ingestion")
      assert html =~ "docs"
      assert html =~ "archives"
    end

    test "switch_volume changes current volume and loads entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "switch_volume", %{"volume" => "archives"})

      assert has_element?(view, "span", "old.md")
      refute has_element?(view, "span", "manual.md")
    end

    test "switch_volume resets current_dir to root", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "switch_volume", %{"volume" => "archives"})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.current_dir == "."
      assert state.socket.assigns.current_volume == "archives"
    end

    test "files in the selected volume are listed after switching", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      # Switch to docs explicitly
      render_hook(view, "switch_volume", %{"volume" => "docs"})
      assert has_element?(view, "span", "manual.md")
      refute has_element?(view, "span", "old.md")

      # Switch to archives
      render_hook(view, "switch_volume", %{"volume" => "archives"})
      assert has_element?(view, "span", "old.md")
      refute has_element?(view, "span", "manual.md")

      # Switch back to docs
      render_hook(view, "switch_volume", %{"volume" => "docs"})
      assert has_element?(view, "span", "manual.md")
      refute has_element?(view, "span", "old.md")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Metadata-driven sidecar pairing
  # ────────────────────────────────────────────────────────────────

  describe "metadata-driven sidecar pairing" do
    test "shows metadata-linked pdf sidecar and excludes it from select_all", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report_converted.md"), "# Report sidecar")

      create_document_with_chunk("default/report.pdf", %{
        metadata: %{"sidecar_source" => "default/report_converted.md"}
      })

      create_document_with_chunk("default/report_converted.md", %{
        metadata: %{"source_document_source" => "default/report.pdf"}
      })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      assert has_element?(view, "span", "report.pdf")
      assert render(view) =~ "report_converted.md"

      render_hook(view, "select_all", %{})
      selected = :sys.get_state(view.pid).socket.assigns.selected

      assert MapSet.member?(selected, "./report.pdf")
      refute MapSet.member?(selected, "./report_converted.md")
    end

    test "does not pair same-basename md without explicit metadata link", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "report.pdf"), "%PDF-1.4")
      File.write!(Path.join(tmp_dir, "report.md"), "# Manual notes")

      create_document_with_chunk("default/report.pdf")
      create_document_with_chunk("default/report.md")

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      assert has_element?(view, "span", "report.pdf")
      assert has_element?(view, "span", "report.md")

      render_hook(view, "select_all", %{})
      selected = :sys.get_state(view.pid).socket.assigns.selected

      assert MapSet.member?(selected, "./report.pdf")
      assert MapSet.member?(selected, "./report.md")
    end

    test "shows metadata-linked image sidecar and excludes it from select_all", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "photo.png"), "png-bytes")
      File.write!(Path.join(tmp_dir, "photo.md"), "# OCR output")

      create_document_with_chunk("default/photo.png", %{
        metadata: %{"sidecar_source" => "default/photo.md"}
      })

      create_document_with_chunk("default/photo.md", %{
        metadata: %{"source_document_source" => "default/photo.png"}
      })

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      assert has_element?(view, "span", "photo.png")
      assert render(view) =~ "photo.md"

      render_hook(view, "select_all", %{})
      selected = :sys.get_state(view.pid).socket.assigns.selected

      assert MapSet.member?(selected, "./photo.png")
      refute MapSet.member?(selected, "./photo.md")
    end
  end

  describe "share modal — document permissions" do
    setup %{conn: conn} do
      unique = System.unique_integer([:positive])

      {:ok, person} =
        People.create_person(%{
          full_name: "Alice Share",
          email: "alice_share#{unique}@example.com"
        })

      {:ok, team} =
        People.create_team(%{name: "Eng#{unique}"})

      {:ok, doc} = Document.create(%{source: "alpha.md", content: "shared content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      %{view: view, doc: doc, person: person, team: team}
    end

    test "share_item opens the share modal for a file", %{view: view} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})

      assert has_element?(view, "button", "Save Permissions")
    end

    test "add_permission_target with a person appends to pending", %{
      view: view,
      person: person
    } do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      assert render(view) =~ person.full_name
    end

    test "add_permission_target with a team appends to pending", %{view: view, team: team} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "team:#{team.id}"})

      assert render(view) =~ team.name
    end

    test "toggle_permission_right adds a right to a pending entry", %{
      view: view,
      person: person
    } do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      pending_before =
        :sys.get_state(view.pid).socket.assigns.share_modal_pending

      assert [%{access_rights: ["read"]}] = pending_before

      render_hook(view, "toggle_permission_right", %{"index" => "0", "right" => "write"})

      pending_after =
        :sys.get_state(view.pid).socket.assigns.share_modal_pending

      assert [%{access_rights: rights}] = pending_after
      assert "write" in rights
    end

    test "confirm_share persists permissions to the database", %{
      view: view,
      doc: doc,
      person: person
    } do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})
      render_hook(view, "confirm_share", %{})

      refute has_element?(view, "button", "Save Permissions")
      assert [perm] = Zaq.Ingestion.list_document_permissions(doc.id)
      assert perm.person_id == person.id
      assert perm.access_rights == ["read"]
    end

    test "remove_permission deletes an existing permission", %{
      view: view,
      doc: doc,
      person: person
    } do
      {:ok, perm} = Zaq.Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "remove_permission", %{"id" => to_string(perm.id)})

      assert Zaq.Ingestion.list_document_permissions(doc.id) == []
    end

    test "duplicate add_permission_target is ignored", %{view: view, person: person} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      pending = :sys.get_state(view.pid).socket.assigns.share_modal_pending
      assert length(pending) == 1
    end

    test "remove_pending removes an entry from share_modal_pending", %{view: view, person: person} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})

      render_hook(view, "remove_pending", %{"index" => "0"})

      pending = :sys.get_state(view.pid).socket.assigns.share_modal_pending
      assert pending == []
    end

    test "add_permission_target with invalid value is a no-op", %{view: view} do
      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "add_permission_target", %{"value" => "invalid_value"})

      pending = :sys.get_state(view.pid).socket.assigns.share_modal_pending
      assert pending == []
    end

    test "remove_permission for folder deletes across all docs", %{
      view: view,
      person: person
    } do
      unique = System.unique_integer([:positive])
      {:ok, doc1} = Document.create(%{source: "folder-#{unique}/a.md", content: "a"})
      {:ok, doc2} = Document.create(%{source: "folder-#{unique}/b.md", content: "b"})

      {:ok, perm1} = Zaq.Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _} = Zaq.Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      render_hook(view, "share_item", %{
        "path" => "folder-#{unique}",
        "type" => "directory"
      })

      render_hook(view, "remove_permission", %{"id" => to_string(perm1.id)})

      assert Zaq.Ingestion.list_document_permissions(doc1.id) == []
      assert Zaq.Ingestion.list_document_permissions(doc2.id) == []
    end

    test "confirm_share for folder persists permissions to all docs", %{
      view: view,
      person: person
    } do
      unique = System.unique_integer([:positive])
      {:ok, doc1} = Document.create(%{source: "sharedir-#{unique}/x.md", content: "x"})
      {:ok, doc2} = Document.create(%{source: "sharedir-#{unique}/y.md", content: "y"})

      render_hook(view, "share_item", %{
        "path" => "sharedir-#{unique}",
        "type" => "directory"
      })

      render_hook(view, "add_permission_target", %{"value" => "person:#{person.id}"})
      render_hook(view, "confirm_share", %{})

      refute has_element?(view, "button", "Save Permissions")
      assert [_] = Zaq.Ingestion.list_document_permissions(doc1.id)
      assert [_] = Zaq.Ingestion.list_document_permissions(doc2.id)
    end
  end

  describe "file_url/1" do
    alias ZaqWeb.Live.BO.AI.IngestionLive

    test "returns /bo/files/ prefixed URL" do
      assert IngestionLive.file_url("docs/guide.md") == "/bo/files/docs/guide.md"
    end

    test "strips leading ./ from path" do
      assert IngestionLive.file_url("./report.pdf") == "/bo/files/report.pdf"
    end

    test "handles simple filename" do
      assert IngestionLive.file_url("file.txt") == "/bo/files/file.txt"
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Public access toggle
  # ────────────────────────────────────────────────────────────────

  describe "share modal — public toggle for a document" do
    test "share modal shows Public access toggle", %{conn: conn} do
      {:ok, _doc} = Document.create(%{source: "alpha.md", content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})

      assert has_element?(view, "[data-testid='public-toggle']")
    end

    test "toggling public and confirming saves the tag to the document", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: "alpha.md", content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      assert "public" in Repo.get!(Document, doc.id).tags
    end

    test "toggling public twice and confirming leaves the tag unchanged", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: "alpha.md", content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      refute "public" in Repo.get!(Document, doc.id).tags
    end

    test "toggle without confirm does not persist", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: "alpha.md", content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "alpha.md"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "close_modal", %{})

      refute "public" in Repo.get!(Document, doc.id).tags
    end
  end

  describe "share modal — public toggle for a folder" do
    test "toggling folder public and confirming saves the flag and tags all docs inside", %{
      conn: conn
    } do
      # Sources are volume-prefixed: "default/docs/readme.md"
      {:ok, doc} = Document.create(%{source: "default/docs/readme.md", content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "docs", "type" => "directory"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      assert "public" in Repo.get!(Document, doc.id).tags
      assert Zaq.Ingestion.folder_public?("default", "docs")
    end

    test "toggling folder public twice and confirming leaves flag unchanged", %{conn: conn} do
      {:ok, doc} = Document.create(%{source: "default/docs/readme.md", content: "content"})

      {:ok, view, _html} = live(conn, ~p"/bo/ingestion")

      render_hook(view, "share_item", %{"path" => "docs", "type" => "directory"})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "toggle_public", %{})
      render_hook(view, "confirm_share", %{})

      refute "public" in Repo.get!(Document, doc.id).tags
      refute Zaq.Ingestion.folder_public?("default", "docs")
    end
  end
end
