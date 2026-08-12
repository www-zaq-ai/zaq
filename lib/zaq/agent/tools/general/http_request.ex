defmodule Zaq.Agent.Tools.General.HttpRequest do
  @moduledoc """
  ReAct tool: turns what the agent read in an API's documentation into an HTTP
  request, sends it, and returns the response — in one turn.

      read the docs (web browsing / knowledge base)
        → http_request   (this tool: validate → dispatch → response)

  The tool performs no I/O itself. It validates the parameters into a
  `Zaq.HttpRequest`, then dispatches `:http_request` to the channels
  role through `NodeRouter.dispatch/1`, where `Zaq.Channels.HttpClient` opens
  the socket. The agent node never connects, and never holds a credential.

  ## Why this is one tool and not two

  It used to be two: one to build a spec, one to send it. The model never
  inspected the spec in between — it handed it straight back — so the split
  cost a turn and bought nothing. Worse, it forced the spec through the model's
  context as JSON, which meant re-validating whatever came back.

  Keeping the LLM out of the network path does not need a second tool call: the
  `%Zaq.HttpRequest{}` struct plus the NodeRouter hop already
  guarantee it.

  ## Validation lives in `Zaq.HttpRequest`

  This module is the tool surface — schema, description, and result shaping.
  Every rule about what makes a request valid (URL form, header and query
  shape, auth rendering, body/format agreement, destination allowlist) lives in
  `Zaq.HttpRequest.build/2`, so a workflow step can build the same
  spec without going through a tool call.

  A build failure short-circuits: nothing is dispatched and no socket opens.

  ## Authenticated endpoints are not supported

  There is no credential mechanism here, deliberately. A literal
  `authorization` or `proxy-authorization` header is rejected: the model writes
  tool parameters, so a token passed that way would enter its context and be
  persisted in conversation history and every export of it.

  That confines this tool to endpoints needing no authorization. Supporting the
  rest needs a named reference resolved on the channels node — see
  `Zaq.HttpRequest`.

  ## Expected context keys

  - `:node_router` — override the NodeRouter module (default `Zaq.NodeRouter`).
  """

  use Zaq.Engine.Workflows.Action,
    name: "http_request",
    description: """
    Send an HTTP request to an external API and return its response.

    USE THIS TOOL after you have read the API documentation (via the web
    browsing or knowledge base tools) and know the exact endpoint, method,
    headers, and body shape the API expects. Pass what the docs told you;
    do not guess an endpoint you have not read.

    This actually sends the request, and sending is not free or reversible.
    Send each request ONCE. If the response is an error status, report it to
    the user and ask before retrying — a POST or PUT that returned an error may
    still have taken effect on the remote system.

    Set `body_format` to match the docs: "json" for a JSON body (the default),
    "form" for form-encoded fields, "raw" for a pre-serialised string body.
    GET and DELETE must not carry a body.

    This tool CANNOT authenticate. It works only against endpoints that need
    no credentials. NEVER put an API key, token, or password in `headers` —
    an `authorization` header is rejected, because anything you write here is
    stored in this conversation's history. If an endpoint needs a credential,
    say so and stop; do not try to work around it.

    The response has `status`, `success` (true for 2xx), `headers`, and `body`.
    A large body is truncated and `truncated` is set to true; if you need the
    rest, narrow the request with query parameters rather than resending.
    """,
    schema:
      Zoi.object(%{
        method:
          Zoi.enum(["GET", "POST", "PUT", "PATCH", "DELETE"],
            description: "HTTP method the documentation specifies for this endpoint"
          ),
        url:
          Zoi.string(
            description: "Absolute http:// or https:// endpoint URL, without a query string"
          ),
        headers:
          Zoi.map(Zoi.string(), Zoi.string(),
            description:
              ~s|Non-secret request headers, e.g. %{"content-type" => "application/json"}. | <>
                ~s|Never put a credential here — an authorization header is rejected|
          )
          |> Zoi.default(%{}),
        query:
          Zoi.map(Zoi.string(), Zoi.union([Zoi.string(), Zoi.number(), Zoi.boolean()]),
            description: "Query string parameters as a flat map of string keys to scalar values"
          )
          |> Zoi.default(%{}),
        body:
          Zoi.any(
            description:
              ~s|Request body: a map for the "json" and "form" formats, a string | <>
                ~s|for "raw". Must be omitted for GET and DELETE|
          )
          |> Zoi.optional(),
        body_format:
          Zoi.enum(["json", "form", "raw"],
            description: ~s|How to encode the body: "json", "form" (url-encoded), or "raw"|
          )
          |> Zoi.default("json"),
        timeout_ms:
          Zoi.integer(description: "Receive timeout in milliseconds")
          |> Zoi.positive()
          |> Zoi.default(30_000),
        doc_reference:
          Zoi.string(
            description:
              "Where this request shape came from — doc URL or section, for traceability"
          )
          |> Zoi.default("")
      }),
    output_schema:
      Zoi.object(%{
        status: Zoi.integer(description: "HTTP response status code"),
        success: Zoi.boolean(description: "True when the status is 2xx"),
        headers: Zoi.map(Zoi.string(), Zoi.string(), description: "Response headers, lowercased"),
        body: Zoi.any(description: "Response body, decoded when JSON") |> Zoi.nullable(),
        truncated:
          Zoi.boolean(description: "True when the body was cut short to fit the agent's context"),
        url: Zoi.string(description: "URL the request was sent to")
      })

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Event
  alias Zaq.HttpRequest
  alias Zaq.NodeRouter

  # Dispatched inline rather than through `DataSourceTool.dispatch/5`: that helper
  # wraps the payload for datasource-shaped calls, which this is not. Response
  # shaping is still shared.
  @impl Jido.Action
  def run(params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    with {:ok, request} <- HttpRequest.build(params) do
      %{request: request}
      |> Event.new(:channels, opts: [action: :http_request])
      |> node_router.dispatch()
      |> Map.fetch!(:response)
      |> DataSourceTool.format_response("HTTP request failed", &{:ok, &1})
    end
  end
end
