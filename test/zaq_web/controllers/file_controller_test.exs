defmodule ZaqWeb.FileControllerTest do
  use ZaqWeb.ConnCase, async: false

  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "file_controller_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_file_controller_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    original_ingestion_env = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: tmp_dir)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original_ingestion_env || [])
      File.rm_rf!(tmp_dir)
    end)

    {:ok, conn: conn, tmp_dir: tmp_dir}
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
end
