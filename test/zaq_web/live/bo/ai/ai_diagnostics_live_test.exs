defmodule ZaqWeb.Live.BO.AI.AIDiagnosticsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Embedding.Client, as: EmbeddingClient

  setup %{conn: conn} do
    user = user_fixture(%{username: "ai_diag_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  test "renders diagnostics page with expected elements", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    refute has_element?(view, "button[phx-click='test_llm']")
    refute render(view) =~ "LLM Model"
    assert has_element?(view, "button[phx-click='test_embedding']")
    assert has_element?(view, "a[href='/bo/prompt-templates']")
  end

  test "test_token_estimator handler assigns a result without error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")
    # The button was removed from the template but the handler must still work
    assert render_hook(view, "test_token_estimator", %{})
  end

  test "test_embedding handles API errors", %{conn: conn} do
    Req.Test.stub(EmbeddingClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_embedding']")
    |> render_click()

    assert_diagnostic_error(view, "401")
  end

  test "test_embedding handles client exceptions", %{conn: conn} do
    Req.Test.stub(EmbeddingClient, fn _conn ->
      raise "embedding crash"
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_embedding']")
    |> render_click()

    assert_diagnostic_error(view, "embedding crash")
  end

  test "test_embedding shows connected status on success", %{conn: conn} do
    Req.Test.stub(EmbeddingClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"data" => [%{"embedding" => [0.1, 0.2, 0.3]}]})
      )
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_embedding']")
    |> render_click()

    assert has_element?(view, "span", "connected")
  end

  test "renders dash fallback when ingestion service is unavailable", %{conn: conn} do
    pid = Process.whereis(Zaq.Ingestion.Supervisor)

    on_exit(fn ->
      if pid && Process.whereis(Zaq.Ingestion.Supervisor) == nil do
        Process.register(pid, Zaq.Ingestion.Supervisor)
      end
    end)

    if pid, do: Process.unregister(Zaq.Ingestion.Supervisor)

    try do
      {:ok, _view, html} = live(conn, ~p"/bo/ai-diagnostics")
      assert html =~ "—"
    after
      if pid && Process.whereis(Zaq.Ingestion.Supervisor) == nil do
        Process.register(pid, Zaq.Ingestion.Supervisor)
      end
    end
  end

  test "rescues local query exceptions in document_count and chunk_count and renders dash fallback",
       %{conn: conn} do
    Zaq.Repo.query!("ALTER TABLE documents RENAME COLUMN id TO broken_id")
    Zaq.Repo.query!("CREATE TABLE IF NOT EXISTS chunks (broken_id serial PRIMARY KEY)")

    {:ok, _view, html} = live(conn, ~p"/bo/ai-diagnostics")
    assert html =~ "—"
  end

  defp assert_diagnostic_error(view, message_fragment) do
    assert has_element?(view, "span", "✗ error")

    if message_fragment do
      assert render(view) =~ message_fragment
    end
  end
end
