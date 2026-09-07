defmodule Zaq.TestSupport.BrowserFlowSite do
  @moduledoc """
  Local HTML fixture for a real browser: presentation, contact form and submission.
  The submitted nonce ties the observed POST to the page served to this test.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "GET", request_path: "/"} = conn, opts) do
    send(opts[:test_pid], {:browser_page, "/"})

    html(conn, 200, """
    <!doctype html><html><head><meta charset="utf-8"><title>ZAQ browser fixture</title></head>
    <body><h1>Welcome</h1><p id="intro">A small team building useful software.</p>
    <a id="next" href="/form">Open contact form</a></body></html>
    """)
  end

  def call(%{method: "GET", request_path: "/form"} = conn, opts) do
    send(opts[:test_pid], {:browser_page, "/form"})

    nonce =
      opts
      |> Keyword.fetch!(:nonce)
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    html(conn, 200, """
    <!doctype html><html><head><meta charset="utf-8"><title>Contact form</title></head>
    <body><h1 id="form-heading">Contact the team</h1>
    <form id="contact-form" method="post" action="/submit">
    <input type="hidden" name="nonce" value="#{nonce}">
    <label for="message">Message</label>
    <input id="message" name="message" required
      oninput="document.getElementById('preview').textContent = this.value">
    <output id="preview" for="message"></output>
    <button id="submit" type="submit">Send message</button>
    </form></body></html>
    """)
  end

  def call(%{method: "POST", request_path: "/submit"} = conn, opts) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)

    if params["nonce"] == opts[:nonce] and is_binary(params["message"]) and
         params["message"] != "" do
      send(opts[:test_pid], {:browser_submission, params})

      html(conn, 200, """
      <!doctype html><html><head><meta charset="utf-8"><title>Submitted</title></head>
      <body><p id="confirmation">Submission received.</p></body></html>
      """)
    else
      send_resp(conn, 422, "Invalid form")
    end
  end

  def call(%{method: "GET", request_path: "/favicon.ico"} = conn, _opts),
    do: send_resp(conn, 204, "")

  def call(conn, _opts), do: send_resp(conn, 404, "Not found")

  defp html(conn, status, body),
    do: conn |> put_resp_content_type("text/html") |> send_resp(status, body)
end
