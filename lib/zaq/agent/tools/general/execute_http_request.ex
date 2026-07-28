defmodule Zaq.Agent.Tools.General.ExecuteHttpRequest do
  @moduledoc """
  ReAct tool: sends a request prepared by
  `Zaq.Agent.Tools.General.BuildHttpRequest` and returns the response.

  This is the *execute* half of the pipeline:

      build_http_request  → this tool → Zaq.Channels.Req

  The tool itself performs no I/O. It dispatches `:http_request` to the
  channels role through `NodeRouter.dispatch/1`; `Zaq.Channels.Req` enforces
  destination safety and opens the socket. The agent therefore never reaches
  the network directly — it only names a request and reads the result.

  Note that `{{secret:...}}` placeholders are **not** resolved yet — see the
  note in `Zaq.Channels.Req`. Until that is wired, this tool works only
  against endpoints needing no authorization.

  Requests are **not** idempotent, so the description tells the model to send
  each one once and read the response rather than retrying a `POST` that may
  already have succeeded.

  ## Expected context keys

  - `:node_router` — override the NodeRouter module (default `Zaq.NodeRouter`).
  """

  use Zaq.Engine.Workflows.Action,
    name: "execute_http_request",
    description: """
    Send an HTTP request that build_http_request prepared, and return the
    response status, headers, and body.

    USE THIS TOOL only with a `request` produced by build_http_request — pass
    that map through unchanged.

    This actually sends the request, and sending is not free or reversible.
    Send each request ONCE. If the response is an error status, report it to
    the user and ask before retrying — a POST or PUT that returned an error may
    still have taken effect on the remote system.

    The response has `status`, `success` (true for 2xx), `headers`, and `body`.
    A large body is truncated and `truncated` is set to true; if you need the
    rest, narrow the request with query parameters rather than resending.
    """,
    schema: [
      request: [
        type: :any,
        required: true,
        doc:
          "The `request` map returned by build_http_request — method, url, " <>
            "headers, query, body, body_format. Pass it through unchanged"
      ],
      timeout_ms: [
        type: :pos_integer,
        default: 30_000,
        doc: "Receive timeout in milliseconds"
      ]
    ],
    output_schema: [
      status: [type: :pos_integer, required: true, doc: "HTTP response status code"],
      success: [type: :boolean, required: true, doc: "True when the status is 2xx"],
      headers: [type: :map, required: true, doc: "Response headers, lowercased"],
      body: [type: :any, required: true, doc: "Response body, decoded when JSON"],
      truncated: [
        type: :boolean,
        required: true,
        doc: "True when the body was cut short to fit the agent's context"
      ],
      url: [type: :string, required: true, doc: "URL the request was sent to"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Event
  alias Zaq.NodeRouter

  # Dispatched inline rather than through `DataSourceTool.dispatch/5`: this is
  # not a datasource call, and the timeout has to travel in the event opts,
  # which that helper does not forward. Response shaping is still shared.
  @impl Jido.Action
  def run(%{request: request, timeout_ms: timeout_ms}, context) when is_map(request) do
    node_router = Map.get(context, :node_router, NodeRouter)

    %{request: request}
    |> Event.new(:channels, opts: [action: :http_request, timeout_ms: timeout_ms])
    |> node_router.dispatch()
    |> Map.fetch!(:response)
    |> DataSourceTool.format_response("HTTP request failed", &{:ok, &1})
  end

  def run(%{request: request}, _context),
    do:
      {:error, "request must be the map returned by build_http_request, got: #{inspect(request)}"}
end
