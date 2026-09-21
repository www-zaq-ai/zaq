defmodule Zaq.TestSupport.OAuthProvider do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", request_path: "/authorize"} = conn, opts) do
    conn = fetch_query_params(conn)
    redirect_uri = Map.fetch!(conn.params, "redirect_uri")
    state = Map.fetch!(conn.params, "state")
    challenge = Map.fetch!(conn.params, "code_challenge")
    success_code = "success-#{System.unique_integer([:positive, :monotonic])}"
    send(opts[:test_pid], {:oauth_authorize_request, conn.params})

    html = """
    <!doctype html>
    <html>
      <head><title>OAuth provider fixture</title></head>
      <body>
        <h1>Authorize ZAQ</h1>
        <a href="#{callback_url(redirect_uri, state, %{"code" => success_code})}">Authorize</a>
        <a href="#{callback_url(redirect_uri, state, %{"code" => "token-failure"})}">Fail token exchange</a>
        <a href="#{callback_url(redirect_uri, state, %{"error" => "access_denied"})}">Deny</a>
        <p data-code-challenge="#{html_escape(challenge)}">PKCE enabled</p>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, html)
  end

  def call(%Plug.Conn{method: "POST", request_path: "/token"} = conn, opts) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)
    send(opts[:test_pid], {:oauth_token_request, params})

    if params["code"] == "token-failure" do
      json(conn, 400, %{"error" => "PROVIDER_SECRET_SENTINEL"})
    else
      json(conn, 200, %{
        "access_token" => "ACCESS_SECRET_SENTINEL_#{params["code"]}",
        "refresh_token" => "REFRESH_SECRET_SENTINEL_#{params["code"]}",
        "expires_in" => 3600,
        "token_type" => "Bearer"
      })
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")

  def server(test_pid) do
    port = free_port()

    child_spec =
      {Bandit,
       plug: {__MODULE__, test_pid: test_pid}, scheme: :http, port: port, ip: {127, 0, 0, 1}}

    {child_spec, "http://127.0.0.1:#{port}"}
  end

  defp callback_url(redirect_uri, state, result) do
    query = result |> Map.put("state", state) |> URI.encode_query()
    separator = if URI.parse(redirect_uri).query, do: "&", else: "?"
    html_escape(redirect_uri <> separator <> query)
  end

  defp html_escape(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("connection", "close")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
