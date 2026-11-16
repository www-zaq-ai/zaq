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

  ## Credentials

  A request may reference a BO-managed Auth Credential by `credential_id`.
  Engine prepares credential material and Channels injects it at the outbound
  edge; the value is not an Action parameter. Literal `authorization` or
  `proxy-authorization` headers are still rejected because they would put secrets
  in the model context.

  ## Expected context keys

  - `:node_router` — override the NodeRouter module (default `Zaq.NodeRouter`).
  - `:event_opts` — trusted `confidential: true` suppresses both HTTP dispatch
    events and replaces failures arising within `run/2` with payload-free Jido
    errors. Parameters cannot enable it. Jido validates the schema before `run/2`:
    its diagnostics are unchanged, so Action inputs must be safe for ordinary
    validation logging. This flag is not a blanket secrecy guarantee for arbitrary
    inputs. Jido execution logging options remain caller-owned.
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

    To authenticate, pass `credential_id` for a BO-managed HTTP credential. Do
    not put API keys, tokens, or passwords in `headers`, `query`, or `body` —
    literal authorization headers are rejected because anything written here is
    stored in this conversation's history.

    The response has `status`, `success` (true for 2xx), `headers`, and `body`.
    By default a large body is truncated and `truncated` is set to true; if you
    need the rest, narrow the request with query parameters rather than resending.
    Set `response_format: "raw"` to receive exact entity bytes as Base64 with
    `body_encoding: "base64"` and header value lists. Raw responses include a separate
    `trailers` map with filtered value lists, empty when absent. Signing metadata is
    unreliable for empty, chunked HTTP/1.1 responses due to a transport dependency
    limitation. Raw reception is bounded: an oversized response fails instead of
    returning a truncated body. Content decoding, decompression, and signature
    verification are not performed.
    """,
    schema:
      Zoi.object(%{
        method:
          Zoi.enum(["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE", "QUERY"],
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
        response_format:
          Zoi.enum(["decoded", "raw"],
            description:
              "Decoded response (default), or bounded raw entity bytes as Base64 without decompression"
          )
          |> Zoi.default("decoded"),
        timeout_ms:
          Zoi.integer(description: "Receive timeout in milliseconds")
          |> Zoi.positive()
          |> Zoi.default(30_000),
        credential_id:
          Zoi.integer(
            description:
              "Optional BO-managed HTTP Auth Credential id. Pass only the id, never the secret value."
          )
          |> Zoi.positive()
          |> Zoi.optional(),
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
        headers:
          Zoi.map(Zoi.string(), Zoi.union([Zoi.string(), Zoi.list(Zoi.string())]),
            description: "Filtered lowercase headers; raw mode preserves each header's value list"
          ),
        trailers:
          Zoi.map(Zoi.string(), Zoi.list(Zoi.string()),
            description:
              "Raw mode only: filtered lowercase trailer value lists, empty when absent"
          )
          |> Zoi.optional(),
        body:
          Zoi.any(description: "Decoded body, or Base64 entity bytes in raw mode")
          |> Zoi.nullable(),
        body_encoding:
          Zoi.enum(["base64"], description: "Present only for raw response bodies")
          |> Zoi.optional(),
        truncated:
          Zoi.boolean(description: "True when the body was cut short to fit the agent's context"),
        url: Zoi.string(description: "URL the request was sent to")
      })

  alias Jido.Action.Error
  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Event
  alias Zaq.HttpRequest
  alias Zaq.NodeRouter

  require Logger

  # Dispatched inline rather than through `DataSourceTool.dispatch/5`: that helper
  # wraps the payload for datasource-shaped calls, which this is not. Response
  # shaping is still shared.
  @impl Jido.Action
  def run(params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)
    confidential? = Keyword.get(Map.get(context, :event_opts, []), :confidential) == true

    execute(params, node_router, confidential?)
  end

  defp execute(params, node_router, confidential?) do
    opts =
      if confidential?,
        do: [action: :http_request, confidential: true],
        else: [action: :http_request]

    case HttpRequest.build(params) do
      {:ok, request} ->
        %{request: request}
        |> Event.new(:channels, opts: opts)
        |> node_router.dispatch()
        |> Map.fetch!(:response)
        |> format_response(confidential?)

      error ->
        if confidential?, do: confidential_failure(error, :validation), else: error
    end
  rescue
    error ->
      if confidential? do
        confidential_failure(error, :execution)
      else
        reraise error, __STACKTRACE__
      end
  catch
    kind, reason ->
      if confidential? do
        confidential_failure(kind, :execution)
      else
        :erlang.raise(kind, reason, __STACKTRACE__)
      end
  end

  defp format_response({:ok, response}, _confidential?) when is_map(response), do: {:ok, response}
  defp format_response(error, true), do: confidential_failure(error, :request)

  defp format_response(response, false),
    do: DataSourceTool.format_response(response, "HTTP request failed", &{:ok, &1})

  # Jido logs returned errors; remove payload-bearing reasons before that boundary.
  defp confidential_failure(error, phase) do
    reason =
      case error do
        {:error, reason} when reason in [:response_too_large, :invalid_response_headers] -> reason
        {:error, {:transport_error, _}} -> :transport_error
        _ -> :request_failed
      end

    exception_type = if is_exception(error), do: error.__struct__, else: :unknown

    Logger.warning(
      "[HttpRequest] confidential request failed phase=#{phase} reason=#{reason} " <>
        "exception_type=#{inspect(exception_type)}"
    )

    {:error,
     Error.execution_error("confidential_http_request_failed", %{
       phase: phase,
       reason: reason,
       exception_type: exception_type,
       retry: false
     })}
  end
end
