defmodule ZaqWeb.Live.BO.AI.IngestionLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Repo

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
    assert has_element?(view, "h3", "Delete 0 Item(s)")

    render_hook(view, "close_modal", %{})
    refute has_element?(view, "h3", "Delete 0 Item(s)")

    render_hook(view, "toggle_view_mode", %{"mode" => "grid"})
    assert has_element?(view, "span", "Select all")
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
    assert has_element?(view, "#rename-input")

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
end
