defmodule ZaqWeb.Live.BO.AI.AIDiagnosticsLivePythonTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Ingestion.Python.Runner

  setup %{conn: conn} do
    user = user_fixture(%{username: "ai_diag_python_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: user.id})

    scripts_dir =
      Path.join(System.tmp_dir!(), "zaq-ai-diagnostics-#{System.unique_integer([:positive])}")

    original_config = Application.get_env(:zaq, Runner)

    Application.put_env(
      :zaq,
      Runner,
      Keyword.put(original_config || [], :scripts_dir, scripts_dir)
    )

    on_exit(fn ->
      if is_nil(original_config) do
        Application.delete_env(:zaq, Runner)
      else
        Application.put_env(:zaq, Runner, original_config)
      end

      File.rm_rf!(scripts_dir)
    end)

    %{conn: conn, scripts_dir: scripts_dir}
  end

  test "image-to-text diagnostic reports connected when Python ping succeeds", %{
    conn: conn,
    scripts_dir: scripts_dir
  } do
    File.mkdir_p!(scripts_dir)
    write_python_script(scripts_dir, "import sys\nsys.exit(0)\n")

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_image_to_text']")
    |> render_click()

    assert has_element?(view, "span", "connected")
    refute render(view) =~ "✗ error"
  end

  test "image-to-text diagnostic displays Python ping failure", %{
    conn: conn,
    scripts_dir: scripts_dir
  } do
    File.mkdir_p!(scripts_dir)
    write_python_script(scripts_dir, "print('PING_FAILED')\nimport sys\nsys.exit(17)\n")

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_image_to_text']")
    |> render_click()

    assert has_element?(view, "span", "✗ error")
    assert render(view) =~ "PING_FAILED"
  end

  test "PDF diagnostic reports missing Python scripts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    render_hook(view, "test_pdf_pipeline", %{})

    assert render(view) =~ "Scripts not found. Run: mix zaq.python.fetch"
  end

  test "PDF diagnostic reports installed Python as available", %{
    conn: conn,
    scripts_dir: scripts_dir
  } do
    File.mkdir_p!(scripts_dir)

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")
    assert render(view) =~ "not tested"

    render_hook(view, "test_pdf_pipeline", %{})

    assert render(view) =~ "available"
  end

  defp write_python_script(scripts_dir, contents) do
    path = Path.join(scripts_dir, "image_to_text.py")
    File.write!(path, contents)
  end
end
