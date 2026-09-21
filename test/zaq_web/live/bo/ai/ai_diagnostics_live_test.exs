defmodule ZaqWeb.Live.BO.AI.AIDiagnosticsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.PromptTemplate
  alias Zaq.Embedding.Client, as: EmbeddingClient
  alias Zaq.Ingestion.Python.Runner
  alias Zaq.TestSupport.OpenAIStub

  setup %{conn: conn} do
    user = user_fixture(%{username: "ai_diag_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  defp seed_retrieval_prompt do
    case PromptTemplate.get_by_slug("retrieval") do
      nil ->
        {:ok, _} =
          PromptTemplate.create(%{
            slug: "retrieval",
            name: "Retrieval Prompt",
            body: "Rewrite the question into search queries. Respond in JSON.",
            description: "System prompt for the retrieval agent",
            active: true
          })

      template ->
        {:ok, _} = PromptTemplate.update(template, %{active: true})
    end
  end

  test "renders diagnostics page with expected elements", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    assert has_element?(view, "button[phx-click='test_llm']")
    assert has_element?(view, "button[phx-click='test_embedding']")
    assert has_element?(view, "a[href='/bo/prompt-templates']")
  end

  test "test_token_estimator handler assigns a result without error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")
    # The button was removed from the template but the handler must still work
    assert render_hook(view, "test_token_estimator", %{})
  end

  test "test_llm shows connected state on HTTP 200", %{conn: conn} do
    seed_retrieval_prompt()

    {child_spec, endpoint} =
      OpenAIStub.server(
        fn _conn, _body -> {200, OpenAIStub.chat_completion("{}")} end,
        self()
      )

    start_supervised!(child_spec)
    OpenAIStub.seed_llm_config(endpoint)

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_llm']")
    |> render_click()

    assert has_element?(view, "span", "connected")
  end

  test "test_llm handles config exceptions", %{conn: conn} do
    OpenAIStub.seed_llm_config("http://[::1")

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_llm']")
    |> render_click()

    assert_diagnostic_error(view)
  end

  test "test_llm shows error on non-200 response", %{conn: conn} do
    seed_retrieval_prompt()

    {child_spec, endpoint} =
      OpenAIStub.server(fn _conn, _body -> {503, %{"error" => "down"}} end, self())

    start_supervised!(child_spec)
    OpenAIStub.seed_llm_config(endpoint)

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_llm']")
    |> render_click()

    assert_diagnostic_error(view, "503")
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

  # Points Runner.scripts_dir/0 at `dir` for the duration of the test.
  defp put_scripts_dir(dir) do
    previous = Application.get_env(:zaq, Runner)
    Application.put_env(:zaq, Runner, scripts_dir: dir)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:zaq, Runner)
        config -> Application.put_env(:zaq, Runner, config)
      end
    end)
  end

  defp temp_dir do
    dir = Path.join(System.tmp_dir!(), "zaq_ai_diag_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Shadows `table` on this test's connection with a temp view whose rows cannot be
  # produced, so exactly one of mount's queries raises while every other query keeps
  # working. Session-local and rolled back with the sandbox transaction — it takes no
  # lock on the real table, so concurrent tests are unaffected.
  defp break_table(table) do
    Zaq.Repo.query!("""
    CREATE FUNCTION pg_temp.zaq_diag_boom() RETURNS boolean AS $$
    BEGIN RAISE EXCEPTION 'zaq diagnostics test'; END $$ LANGUAGE plpgsql
    """)

    Zaq.Repo.query!("CREATE TEMP VIEW #{table} AS SELECT 1 AS id WHERE pg_temp.zaq_diag_boom()")
  end

  describe "test_image_to_text" do
    @tag capture_log: true
    test "reports an error when the python step cannot run", %{conn: conn} do
      # No image_to_text.py under the scripts dir, so ImageToText.ping/0 always
      # comes back {:error, output} — whether python resolves or not.
      put_scripts_dir(temp_dir())

      {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

      view
      |> element("button[phx-click='test_image_to_text']")
      |> render_click()

      assert_diagnostic_error(view)
    end
  end

  describe "test_pdf_pipeline" do
    test "reports missing scripts when the scripts dir does not exist", %{conn: conn} do
      put_scripts_dir(
        Path.join(System.tmp_dir!(), "zaq_absent_#{System.unique_integer([:positive])}")
      )

      {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

      assert render_hook(view, "test_pdf_pipeline", %{}) =~ "Scripts not found"
    end

    test "probes the python executable when the scripts dir exists", %{conn: conn} do
      put_scripts_dir(temp_dir())

      {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

      html = render_hook(view, "test_pdf_pipeline", %{})

      # The probe runs `python3 --version`; the reported status follows whether a
      # python executable is resolvable in this environment.
      if System.find_executable(Runner.python_executable()) do
        assert html =~ "available"
      else
        assert html =~ "Python unavailable" or html =~ "enoent"
      end

      refute html =~ "Scripts not found"
    end
  end

  describe "mount degrades when a query fails" do
    test "falls back to an empty template list", %{conn: conn} do
      break_table("prompt_templates")

      {:ok, _view, html} = live(conn, ~p"/bo/ai-diagnostics")

      assert html =~ "No Templates Found"
    end

    test "falls back to an unknown document count", %{conn: conn} do
      break_table("documents")

      {:ok, _view, html} = live(conn, ~p"/bo/ai-diagnostics")

      assert html =~ ~r/—\s*<span[^>]*>\s*docs/
    end

    test "falls back to an unknown chunk count", %{conn: conn} do
      break_table("chunks")

      {:ok, _view, html} = live(conn, ~p"/bo/ai-diagnostics")

      assert html =~ ~r/—\s*<span[^>]*>\s*chunks/
      refute html =~ ~r/—\s*<span[^>]*>\s*docs/
    end
  end

  defp assert_diagnostic_error(view, message_fragment \\ nil) do
    assert has_element?(view, "span", "✗ error")

    if message_fragment do
      assert render(view) =~ message_fragment
    end
  end
end
