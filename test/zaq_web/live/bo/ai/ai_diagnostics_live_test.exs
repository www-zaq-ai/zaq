defmodule ZaqWeb.Live.BO.AI.AIDiagnosticsLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.LLM
  alias Zaq.Embedding.Client, as: EmbeddingClient

  setup %{conn: conn} do
    user = user_fixture(%{username: "ai_diag_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    llm_env = Application.get_env(:zaq, LLM)
    embedding_env = Application.get_env(:zaq, EmbeddingClient)

    on_exit(fn ->
      Application.put_env(:zaq, LLM, llm_env)
      Application.put_env(:zaq, EmbeddingClient, embedding_env)
    end)

    %{conn: conn}
  end

  test "renders diagnostics and computes token estimator sample", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    assert has_element?(view, "button[phx-click='test_llm']")
    assert has_element?(view, "button[phx-click='test_embedding']")
    assert has_element?(view, "button[phx-click='test_token_estimator']")
    assert has_element?(view, "a[href='/bo/prompt-templates']")

    view
    |> element("button[phx-click='test_token_estimator']")
    |> render_click()

    assert has_element?(view, "span", "12 tokens")
  end

  test "test_llm shows connected state on HTTP 200", %{conn: conn} do
    base_url =
      start_stub_server(fn conn, body ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/chat/completions"

        assert %{"model" => _model, "messages" => [%{"content" => "ping"}], "max_tokens" => 1} =
                 Jason.decode!(body)

        {200, %{"id" => "cmpl-1"}}
      end)

    Application.put_env(:zaq, LLM,
      endpoint: base_url <> "/v1",
      api_key: "",
      model: "test-model",
      temperature: 0.0,
      top_p: 0.9,
      supports_logprobs: false,
      supports_json_mode: false
    )

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_llm']")
    |> render_click()

    assert has_element?(view, "span", "connected")
  end

  test "test_llm handles config exceptions", %{conn: conn} do
    Application.put_env(:zaq, LLM,
      endpoint: "http://[::1",
      api_key: "",
      model: "test-model",
      temperature: 0.0,
      top_p: 0.9,
      supports_logprobs: false,
      supports_json_mode: false
    )

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_llm']")
    |> render_click()

    assert has_element?(view, "p.text-red-500")
  end

  test "test_llm shows error on non-200 response", %{conn: conn} do
    base_url =
      start_stub_server(fn _conn, _body ->
        {503, %{"error" => "down"}}
      end)

    Application.put_env(:zaq, LLM,
      endpoint: base_url <> "/v1",
      api_key: "",
      model: "test-model",
      temperature: 0.0,
      top_p: 0.9,
      supports_logprobs: false,
      supports_json_mode: false
    )

    {:ok, view, _html} = live(conn, ~p"/bo/ai-diagnostics")

    view
    |> element("button[phx-click='test_llm']")
    |> render_click()

    assert has_element?(view, "p.text-red-500", "HTTP 503")
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

  defp start_stub_server(handler) do
    port = free_port()

    start_supervised!(
      {Bandit, plug: {__MODULE__.StubPlug, handler: handler}, scheme: :http, port: port}
    )

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defmodule StubPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)

      case opts[:handler].(conn, body) do
        {status, response} when is_map(response) or is_list(response) ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(response))

        {status, response} ->
          send_resp(conn, status, response)
      end
    end
  end
end
