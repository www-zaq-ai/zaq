defmodule ZaqWeb.Live.BO.AI.AIDiagnosticsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.PromptTemplate
  alias Zaq.Embedding.Client, as: EmbeddingClient
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

    assert has_element?(view, "p.text-red-500")
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

    assert has_element?(view, "p.text-red-500")
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

    assert has_element?(view, "p.text-red-500")
  end

  test "test_embedding handles client exceptions", %{conn: conn} do
    Req.Test.stub(EmbeddingClient, fn _conn ->
      raise "embedding crash"
    end)

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_embedding']")
    |> render_click()

    assert has_element?(view, "p.text-red-500", "embedding crash")
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
end
