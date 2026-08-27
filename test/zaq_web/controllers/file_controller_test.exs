defmodule ZaqWeb.FileControllerTest do
  use ZaqWeb.ConnCase, async: false

  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.Document
  alias Zaq.Repo
  alias Zaq.Storage.Materializers.DiskDocument
  alias ZaqWeb.PreviewReference

  setup %{conn: conn} do
    user = super_admin_fixture(%{username: "file_controller_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_file_controller_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    original_storage_env = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: tmp_dir, volumes: %{})

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Storage, original_storage_env || [])
      File.rm_rf!(tmp_dir)
    end)

    {:ok, conn: conn, tmp_dir: tmp_dir, user: user}
  end

  describe "GET /bo/files/*path" do
    test "serves file with content-type and content-disposition", %{conn: conn, tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "guide.md")
      File.write!(file_path, "# Hello")

      conn = get(conn, "/bo/files/guide.md")

      assert response(conn, 200) == "# Hello"
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="guide.md")]
      assert List.first(get_resp_header(conn, "content-type")) =~ "text/markdown"
    end

    test "returns forbidden for path traversal", %{conn: conn} do
      conn = get(conn, "/bo/files/%2e%2e/secret.txt")

      assert response(conn, 403) == "Forbidden"
    end

    test "returns forbidden for an unauthorized document before checking the file", %{
      conn: conn
    } do
      admin = admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: admin.id})

      assert {:ok, _document} = Document.create(%{source: "restricted.md", content: "private"})

      conn = get(conn, "/bo/files/restricted.md")

      assert response(conn, 403) == "Access denied"
      refute response(conn, 403) == "File not found"
    end

    test "falls back to storage when the ingestion configuration is absent", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "storage-only.txt"), "storage content")
      Application.delete_env(:zaq, Zaq.Ingestion)

      conn = get(conn, "/bo/files/storage-only.txt")

      assert response(conn, 200) == "storage content"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(inline; filename="storage-only.txt")
             ]

      assert List.first(get_resp_header(conn, "content-type")) =~ "text/plain"
    end

    test "returns not found for missing files", %{conn: conn} do
      conn = get(conn, "/bo/files/missing.txt")

      assert response(conn, 404) == "File not found"
    end

    test "returns bad request for directory paths", %{conn: conn, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "docs"))

      conn = get(conn, "/bo/files/docs")

      assert response(conn, 400) == "Not a file"
    end

    test "returns internal server error when file cannot be read", %{conn: conn, tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "restricted.txt")
      File.write!(file_path, "private")
      File.chmod!(file_path, 0o000)

      on_exit(fn ->
        if File.exists?(file_path) do
          File.chmod!(file_path, 0o644)
        end
      end)

      conn = get(conn, "/bo/files/restricted.txt")

      assert response(conn, 500) == "Could not read file"
    end
  end

  describe "GET /bo/files/ref/:token" do
    test "serves materialized disk bytes from the signed preview reference", %{
      conn: conn,
      tmp_dir: tmp_dir,
      user: user
    } do
      File.mkdir_p!(Path.join(tmp_dir, "stored/archive"))

      File.write!(
        Path.join(tmp_dir, "stored/archive/pixel.png"),
        <<137, 80, 78, 71, 13, 10, 26, 10>>
      )

      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Disk raw preview",
          provider: "disk",
          kind: "data_source",
          enabled: true,
          settings: %{"volumes" => [%{"name" => "archives", "path" => "stored/archive"}]}
        })
        |> Repo.insert!()

      {:ok, handle} = DiskDocument.issue("archives/pixel.png", %{"config_id" => config.id})

      record = %Record{
        id: "archives/pixel.png",
        kind: :file,
        name: "pixel.png",
        mime_type: "image/png",
        materialization_handle: handle,
        attributes: %{"provider" => "disk", "config_id" => "archives"}
      }

      token = PreviewReference.sign_record(record, user)
      conn = get(conn, "/bo/files/ref/#{token}")

      assert response(conn, 200) == <<137, 80, 78, 71, 13, 10, 26, 10>>
      assert List.first(get_resp_header(conn, "content-type")) =~ "image/png"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "rejects tampered preview references", %{conn: conn, user: user} do
      {:ok, handle} = DiskDocument.issue("archives/pixel.png", %{"config_id" => 123})

      token =
        PreviewReference.sign_record(
          %Record{
            id: "archives/pixel.png",
            kind: :file,
            name: "pixel.png",
            materialization_handle: handle,
            attributes: %{"provider" => "disk", "config_id" => "archives"}
          },
          user
        )

      conn = get(conn, "/bo/files/ref/#{token <> "tampered"}")

      assert response(conn, 404) == "File not found"
    end

    test "rejects an unauthorized signed preview reference before materialization", %{conn: conn} do
      admin = admin_fixture()
      {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
      conn = init_test_session(conn, %{user_id: admin.id})

      assert {:ok, _document} =
               Document.create(%{source: "restricted-ref.md", content: "private"})

      {:ok, handle} = DiskDocument.issue("restricted-ref.md", %{"config_id" => 123})

      record = %Record{
        id: "restricted-ref.md",
        kind: :file,
        name: "restricted-ref.md",
        mime_type: "text/markdown",
        materialization_handle: handle,
        attributes: %{
          "provider" => "local",
          "config_id" => 123,
          "source" => "restricted-ref.md"
        }
      }

      token = PreviewReference.sign_record(record, admin)
      conn = get(conn, "/bo/files/ref/#{token}")

      assert response(conn, 403) == "Access denied"
      refute response(conn, 403) == "File not found"
      assert get_resp_header(conn, "content-disposition") == []
      # The endpoint adds `nosniff` globally; the controller must not add preview headers.
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end
end
