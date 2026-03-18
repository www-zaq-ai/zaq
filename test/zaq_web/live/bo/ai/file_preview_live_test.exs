defmodule ZaqWeb.Live.BO.AI.FilePreviewLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias ZaqWeb.Helpers.DateFormat
  alias ZaqWeb.Live.BO.AI.FilePreviewLive

  setup %{conn: conn} do
    user = user_fixture(%{username: "file_preview_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_file_preview_live_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    original_ingestion_env = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: tmp_dir)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original_ingestion_env || [])
      File.rm_rf!(tmp_dir)
    end)

    {:ok, conn: conn, tmp_dir: tmp_dir}
  end

  describe "file preview branches" do
    test "shows not found state for missing files", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/bo/preview/missing.md")

      assert has_element?(view, "p", "File not found")
      assert has_element?(view, "p", "missing.md")
    end

    test "renders markdown files as HTML", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "doc.md"), "# Rendered heading\n\nBody")

      {:ok, view, _html} = live(conn, "/bo/preview/doc.md")

      assert has_element?(view, "span", "md")
      assert has_element?(view, "span", "rendered")
      assert has_element?(view, ".md-content h1", "Rendered heading")
    end

    test "renders plain text files in pre block", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "notes.txt"), "hello plain text")

      {:ok, view, _html} = live(conn, "/bo/preview/notes.txt")

      assert has_element?(view, "span", "plain text")
      assert has_element?(view, "pre", "hello plain text")
    end

    test "renders image preview branch", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "pixel.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)

      {:ok, view, _html} = live(conn, "/bo/preview/pixel.png")

      assert has_element?(view, "span", "image")
      assert has_element?(view, "img[src='/bo/files/pixel.png'][alt='pixel.png']")
    end

    test "renders pdf preview branch", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "sample.pdf"), "%PDF-1.4\n%test")

      {:ok, view, _html} = live(conn, "/bo/preview/sample.pdf")

      assert has_element?(view, "span", "document")
      assert has_element?(view, "iframe[src='/bo/files/sample.pdf'][title='sample.pdf']")
    end

    test "renders binary fallback branch", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "archive.bin"), <<0, 1, 2, 3, 4>>)

      {:ok, view, _html} = live(conn, "/bo/preview/archive.bin")

      assert has_element?(view, "p", "Preview not available")
      assert has_element?(view, "a[download='archive.bin'][href='/bo/files/archive.bin']")
    end

    test "renders binary fallback for docx when Python is unavailable", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      # DOCX magic bytes — Python script won't run in test env → :binary fallback
      File.write!(Path.join(tmp_dir, "doc.docx"), <<80, 75, 3, 4, 0, 0>>)

      {:ok, view, _html} = live(conn, "/bo/preview/doc.docx")

      assert has_element?(view, "p", "Preview not available")
      assert has_element?(view, "a[download='doc.docx']")
    end

    test "renders binary fallback for xlsx when Python is unavailable", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "data.xlsx"), <<80, 75, 3, 4, 0, 0>>)

      {:ok, view, _html} = live(conn, "/bo/preview/data.xlsx")

      assert has_element?(view, "p", "Preview not available")
      assert has_element?(view, "a[download='data.xlsx']")
    end

    test "renders binary fallback for xls when Python is unavailable", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "sheet.xls"), <<0xD0, 0xCF, 0x11, 0xE0>>)

      {:ok, view, _html} = live(conn, "/bo/preview/sheet.xls")

      assert has_element?(view, "p", "Preview not available")
      assert has_element?(view, "a[download='sheet.xls']")
    end

    test "renders plain text for .txt files", %{conn: conn, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "readme.txt"), "just text")

      {:ok, view, _html} = live(conn, "/bo/preview/readme.txt")

      assert has_element?(view, "span", "plain text")
      assert has_element?(view, "pre", "just text")
    end
  end

  describe "helper functions" do
    test "format_size/1 covers nil, bytes, KB, and MB" do
      assert FilePreviewLive.format_size(nil) == "—"
      assert FilePreviewLive.format_size(512) == "512 B"
      assert FilePreviewLive.format_size(2048) == "2.0 KB"
      assert FilePreviewLive.format_size(2_097_152) == "2.0 MB"
    end

    test "format_datetime/1 covers nil and datetime formatting" do
      assert DateFormat.format_datetime(nil) == "—"

      assert DateFormat.format_datetime(~U[2025-01-02 03:04:00Z]) ==
               "2025-01-02 03:04"
    end
  end

  describe "volume-aware file resolution" do
    test "finds files in configured volumes", %{conn: conn} do
      # Create a separate volume directory
      volume_dir = Path.join(System.tmp_dir!(), "zaq_preview_volume_#{System.unique_integer([:positive])}")
      File.mkdir_p!(volume_dir)

      # Configure volumes
      original_ingestion_env = Application.get_env(:zaq, Zaq.Ingestion)
      base_dir = Path.expand(original_ingestion_env[:base_path] || "priv/documents")

      Application.put_env(
        :zaq,
        Zaq.Ingestion,
        Keyword.merge(original_ingestion_env || [], volumes: %{"docs" => volume_dir})
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original_ingestion_env || [])
        File.rm_rf!(volume_dir)
      end)

      # Create file in volume
      file_path = Path.join(volume_dir, "volume_doc.md")
      File.write!(file_path, "# Volume Document")

      # Should find file in volume even without volume prefix in URL
      {:ok, view, _html} = live(conn, "/bo/preview/volume_doc.md")

      assert has_element?(view, ".md-content h1", "Volume Document")
    end

    test "finds files in subdirectories within volumes", %{conn: conn} do
      # Create a separate volume directory with subdirectories
      volume_dir = Path.join(System.tmp_dir!(), "zaq_preview_subdir_#{System.unique_integer([:positive])}")
      subdir = Path.join(volume_dir, "subfolder")
      File.mkdir_p!(subdir)

      # Configure volumes
      original_ingestion_env = Application.get_env(:zaq, Zaq.Ingestion)

      Application.put_env(
        :zaq,
        Zaq.Ingestion,
        Keyword.merge(original_ingestion_env || [], volumes: %{"docs" => volume_dir})
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original_ingestion_env || [])
        File.rm_rf!(volume_dir)
      end)

      # Create file in subdirectory
      file_path = Path.join(subdir, "nested.md")
      File.write!(file_path, "# Nested Document")

      # Should find file in subdirectory within volume
      {:ok, view, _html} = live(conn, "/bo/preview/subfolder/nested.md")

      assert has_element?(view, ".md-content h1", "Nested Document")
    end

    test "respects access control for files in volumes", %{conn: conn} do
      # Create a separate volume directory
      volume_dir = Path.join(System.tmp_dir!(), "zaq_preview_restricted_#{System.unique_integer([:positive])}")
      File.mkdir_p!(volume_dir)

      # Configure volumes
      original_ingestion_env = Application.get_env(:zaq, Zaq.Ingestion)

      Application.put_env(
        :zaq,
        Zaq.Ingestion,
        Keyword.merge(original_ingestion_env || [], volumes: %{"docs" => volume_dir})
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original_ingestion_env || [])
        File.rm_rf!(volume_dir)
      end)

      # Create file
      file_path = Path.join(volume_dir, "restricted.md")
      File.write!(file_path, "# Restricted")

      # Track upload with specific role
      owner_role = role_fixture(%{name: "owner"})
      {:ok, _} = Zaq.Ingestion.track_upload("restricted.md", owner_role.id)

      # Create restricted user
      restricted_role = role_fixture(%{name: "restricted"})
      restricted_user = user_fixture(%{role_id: restricted_user.id})
      {:ok, restricted_user} = Accounts.change_password(restricted_user, %{password: "StrongPass1!"})

      # Login as restricted user
      conn = init_test_session(conn, %{user_id: restricted_user.id})

      # Should redirect to ingestion page due to access denied
      {:error, {:redirect, %{to: "/bo/ingestion"}}} = live(conn, "/bo/preview/restricted.md")
    end
  end
end
