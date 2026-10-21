defmodule Zaq.TestSupport.WidgetBrowserParent do
  @moduledoc """
  Local embedding application for the real widget browser journey.

  Like a parent application's authenticated backend, this fixture signs a fresh
  connector-scoped identity server-side. It serves only fixture HTML and tokens;
  every widget request goes to the real host Endpoint, never through this plug.
  """

  import Plug.Conn

  alias WebWidget.Integration.SignedIdentity

  def init(opts), do: opts

  def call(conn, opts) do
    conn = fetch_query_params(conn)

    case conn.request_path do
      "/token" ->
        widget = Agent.get(opts[:state], &Map.fetch!(&1, conn.query_params["widget"]))

        {:ok, token} =
          SignedIdentity.sign(widget.token, widget.id, %{user_id: "widget-browser-person"},
            issuer: widget.settings["identity_issuer"],
            audience: widget.settings["identity_audience"]
          )

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{identity_token: token}))

      "/" ->
        widget = Agent.get(opts[:state], &Map.fetch!(&1, conn.query_params["widget"]))
        host = conn.query_params["host"]
        # Both origins are ephemeral local listeners owned by this test.
        %URI{scheme: "http", host: "localhost", port: port} = URI.parse(host)
        true = is_integer(port) and port > 0

        html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body><h1>Widget acceptance</h1><div id="widget-container" style="height:85vh"></div>
        <script src="#{host}/channels/web_widget/assets/embed.js"
          data-widget-id="#{widget.id}" data-widget-url="#{host}/channels/widget/#{widget.id}"
          data-token-url="/token?widget=#{widget.id}" iframe-location-id="#widget-container"></script>
        </body></html>
        """

        conn |> put_resp_content_type("text/html") |> send_resp(200, html)

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end
end
