defmodule Zaq.Agent.Tools.General.BuildHttpRequest do
  @moduledoc """
  ReAct tool: turns what the agent read in an API's documentation into a
  validated HTTP request spec, ready to be executed by a `Req` client.

  This tool **never performs the request**. It is the *prepare* half of a
  two-step pattern:

      read the docs (web browsing / knowledge base)
        → build_http_request   (this tool — validates and normalises)
        → a downstream step executes it with `Req`

  Splitting the two keeps the LLM out of the network path: the agent decides
  *what* to send, and the executor decides *whether and how* to send it.

  ## Secrets are references, never values

  The built request never contains a literal credential. Authorization is
  declared as a **reference** and rendered as a `{{secret:name}}` placeholder:

      auth: %{"type" => "bearer", "ref" => "stripe_key"}
      #=> headers: %{"authorization" => "Bearer {{secret:stripe_key}}"}
      #=> secret_refs: ["stripe_key"]

  The executor resolves every ref in `secret_refs` at send time. Because the
  tool result is fed back into the model's context and persisted in
  conversation history, a literal token passed here would leak — so a raw
  `authorization` header is rejected outright with a message pointing at
  `auth`. Placeholders may also appear by hand in any header, query, or body
  value; every one found is collected into `secret_refs`.

  ## Output

  - `:request` — normalised spec (`method`, `url`, `headers`, `query`, `body`,
    `body_format`).
  - `:req_options` — the same spec as a keyword list that can be handed
    straight to `Req.request/1` once placeholders are resolved.
  - `:secret_refs` — every distinct `{{secret:...}}` name the executor must
    resolve before sending.

  ## Expected context keys

  None. This action is pure — it performs no I/O and reads no context.
  """

  use Zaq.Engine.Workflows.Action,
    name: "build_http_request",
    description: """
    Build a validated HTTP request from an API's documentation, ready to be
    executed later by the HTTP client. This tool does NOT send the request.

    USE THIS TOOL after you have read the API documentation (via the web
    browsing or knowledge base tools) and know the exact endpoint, method,
    headers, and body shape the API expects. Pass what the docs told you;
    do not guess an endpoint you have not read.

    Set `body_format` to match the docs: "json" for a JSON body (the default),
    "form" for form-encoded fields, "raw" for a pre-serialised string body.
    GET and DELETE must not carry a body.

    NEVER put a real API key, token, or password in `headers`. Declare
    credentials with `auth` instead, naming the credential:

        auth: {"type": "bearer", "ref": "stripe_key"}

    This renders as "Bearer {{secret:stripe_key}}" and the real value is
    substituted at send time. Supported auth types: "bearer", "basic",
    "api_key", "none". A literal `authorization` header is rejected.

    Returns the request spec, a `req_options` keyword list for the HTTP client,
    and `secret_refs` listing every credential the executor must resolve.
    """,
    schema: [
      method: [
        type: {:in, ["GET", "POST", "PUT", "PATCH", "DELETE"]},
        required: true,
        doc: "HTTP method the documentation specifies for this endpoint"
      ],
      url: [
        type: :string,
        required: true,
        doc: "Absolute http:// or https:// endpoint URL, without a query string"
      ],
      # `headers`, `query`, and `auth` are typed `:any` rather than `:map`
      # because NimbleOptions' `:map` accepts atom keys only, while a JSON tool
      # call always produces string keys. Shape is validated in `run/2` instead.
      headers: [
        type: :any,
        default: %{},
        doc:
          ~s|Non-secret request headers, e.g. %{"content-type" => "application/json"}. | <>
            ~s|Never put a credential here — use `auth`|
      ],
      query: [
        type: :any,
        default: %{},
        doc: "Query string parameters as a flat map of string keys to string values"
      ],
      body: [
        type: :any,
        default: nil,
        doc:
          ~s|Request body: a map for the "json" and "form" formats, a string | <>
            ~s|for "raw". Must be omitted for GET and DELETE|
      ],
      body_format: [
        type: {:in, ["json", "form", "raw"]},
        default: "json",
        doc: ~s|How to encode the body: "json", "form" (url-encoded), or "raw"|
      ],
      auth: [
        type: :any,
        default: %{},
        doc:
          ~s|Credential reference, e.g. %{"type" => "bearer", "ref" => "stripe_key"}. | <>
            ~s|Types: "bearer", "basic", "api_key" (optional "header", default | <>
            ~s|"x-api-key"), "none". Pass the credential NAME, never its value|
      ],
      timeout_ms: [
        type: :pos_integer,
        default: 30_000,
        doc: "Receive timeout in milliseconds for the eventual request"
      ],
      doc_reference: [
        type: :string,
        default: "",
        doc: "Where this request shape came from — doc URL or section, for traceability"
      ]
    ],
    output_schema: [
      request: [
        type: :map,
        required: true,
        doc: "Normalised request spec — method, url, headers, query, body, body_format"
      ],
      req_options: [
        type: :keyword_list,
        required: true,
        doc: "Keyword list ready for `Req.request/1` once secret placeholders are resolved"
      ],
      secret_refs: [
        type: {:list, :string},
        required: true,
        doc: "Distinct credential names the executor must resolve before sending"
      ]
    ]

  @secret_placeholder ~r/\{\{secret:([a-zA-Z0-9_.\-]+)\}\}/
  @secret_ref ~r/\A[a-zA-Z0-9_.\-]+\z/
  @bodyless_methods ~w(GET DELETE)
  @default_api_key_header "x-api-key"

  @impl Jido.Action
  def run(params, _context) do
    with {:ok, url} <- validate_url(params.url),
         {:ok, raw_headers} <- ensure_map(params.headers, "headers"),
         {:ok, raw_query} <- ensure_map(params.query, "query"),
         {:ok, raw_auth} <- ensure_map(params.auth, "auth"),
         {:ok, headers} <- normalize_headers(raw_headers),
         {:ok, query} <- normalize_query(raw_query),
         {:ok, auth_headers} <- build_auth_headers(raw_auth),
         {:ok, body} <- validate_body(params.method, params.body, params.body_format) do
      request = %{
        method: method_atom(params.method),
        url: url,
        headers: Map.merge(headers, auth_headers),
        query: query,
        body: body,
        body_format: params.body_format,
        doc_reference: params.doc_reference
      }

      {:ok,
       %{
         request: request,
         req_options: req_options(request, params.timeout_ms),
         secret_refs: collect_secret_refs(request)
       }}
    end
  end

  defp ensure_map(nil, _field), do: {:ok, %{}}
  defp ensure_map(value, _field) when is_map(value), do: {:ok, value}

  defp ensure_map(value, field),
    do: {:error, "#{field} must be a map of keys to values, got: #{inspect(value)}"}

  # -- URL --------------------------------------------------------------------

  defp validate_url(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if uri.query in [nil, ""] do
          {:ok, URI.to_string(uri)}
        else
          {:error, "url must not carry a query string — pass those parameters in `query` instead"}
        end

      {:ok, _uri} ->
        {:error, "url must be an absolute http:// or https:// URL with a host, got: #{url}"}

      {:error, _part} ->
        {:error, "url is not a valid URI: #{url}"}
    end
  end

  # -- Headers ----------------------------------------------------------------

  defp normalize_headers(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      name = name |> to_string() |> String.trim() |> String.downcase()

      cond do
        name == "" ->
          {:halt, {:error, "header names must not be blank"}}

        not is_binary(value) ->
          {:halt, {:error, "header #{name} must be a string, got: #{inspect(value)}"}}

        name in ["authorization", "proxy-authorization"] ->
          {:halt,
           {:error,
            "do not pass #{name} as a header — declare the credential with `auth` " <>
              ~s|instead, e.g. %{"type" => "bearer", "ref" => "my_api_token"}|}}

        true ->
          {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  # -- Query ------------------------------------------------------------------

  defp normalize_query(query) do
    Enum.reduce_while(query, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if is_binary(value) or is_number(value) or is_boolean(value) do
        {:cont, {:ok, Map.put(acc, to_string(key), to_string(value))}}
      else
        {:halt,
         {:error,
          "query parameter #{key} must be a string, number, or boolean, " <>
            "got: #{inspect(value)}"}}
      end
    end)
  end

  # -- Auth -------------------------------------------------------------------

  defp build_auth_headers(auth) when map_size(auth) == 0, do: {:ok, %{}}

  defp build_auth_headers(auth) do
    case fetch(auth, :type) do
      nil -> {:error, ~s|auth must declare a "type": "bearer", "basic", "api_key", or "none"|}
      "none" -> {:ok, %{}}
      type when type in ["bearer", "basic", "api_key"] -> auth_header(type, auth)
      other -> {:error, ~s|unsupported auth type: #{inspect(other)}|}
    end
  end

  defp auth_header(type, auth) do
    with {:ok, ref} <- validate_secret_ref(fetch(auth, :ref)) do
      placeholder = "{{secret:#{ref}}}"

      case type do
        "bearer" ->
          {:ok, %{"authorization" => "Bearer #{placeholder}"}}

        "basic" ->
          # The resolver supplies the already-base64-encoded "user:password"
          # pair — this tool never sees either half.
          {:ok, %{"authorization" => "Basic #{placeholder}"}}

        "api_key" ->
          header = api_key_header(fetch(auth, :header))
          {:ok, %{header => prefixed(fetch(auth, :prefix), placeholder)}}
      end
    end
  end

  defp api_key_header(name) when is_binary(name) and name != "",
    do: name |> String.trim() |> String.downcase()

  defp api_key_header(_name), do: @default_api_key_header

  defp prefixed(prefix, placeholder) when is_binary(prefix) and prefix != "",
    do: "#{String.trim(prefix)} #{placeholder}"

  defp prefixed(_prefix, placeholder), do: placeholder

  defp validate_secret_ref(ref) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        {:error, ~s|auth "ref" must name a credential, e.g. "stripe_key"|}

      Regex.match?(@secret_placeholder, ref) ->
        {:error, ~s|auth "ref" is the credential name alone — do not wrap it in {{secret:...}}|}

      not Regex.match?(@secret_ref, ref) ->
        {:error, ~s|auth "ref" may only contain letters, digits, ".", "_", and "-", got: #{ref}|}

      true ->
        {:ok, ref}
    end
  end

  defp validate_secret_ref(_ref),
    do:
      {:error,
       ~s|auth must declare a "ref" naming the credential — never the credential value itself|}

  # -- Body -------------------------------------------------------------------

  defp validate_body(method, body, _format) when method in @bodyless_methods do
    if empty_body?(body),
      do: {:ok, nil},
      else: {:error, "#{method} requests must not carry a body"}
  end

  defp validate_body(_method, body, _format) when body in [nil, ""], do: {:ok, nil}

  defp validate_body(_method, body, "raw") when is_binary(body), do: {:ok, body}

  defp validate_body(_method, body, "raw"),
    do: {:error, ~s|body_format "raw" needs a string body, got: #{inspect(body)}|}

  defp validate_body(_method, body, "json") when is_map(body) or is_list(body), do: {:ok, body}

  defp validate_body(_method, body, "json"),
    do: {:error, ~s|body_format "json" needs a map or list body, got: #{inspect(body)}|}

  defp validate_body(_method, body, "form") when is_map(body), do: {:ok, body}

  defp validate_body(_method, body, "form"),
    do: {:error, ~s|body_format "form" needs a map body, got: #{inspect(body)}|}

  defp empty_body?(body), do: body in [nil, "", %{}, []]

  # -- Req assembly -----------------------------------------------------------

  defp req_options(request, timeout_ms) do
    base = [
      method: request.method,
      url: request.url,
      headers: request.headers,
      receive_timeout: timeout_ms
    ]

    base
    |> maybe_put(:params, request.query, &(map_size(&1) > 0))
    |> maybe_put(body_key(request.body_format), request.body, &(not is_nil(&1)))
  end

  defp body_key("json"), do: :json
  defp body_key("form"), do: :form
  defp body_key("raw"), do: :body

  defp maybe_put(opts, key, value, keep?) do
    if keep?.(value), do: opts ++ [{key, value}], else: opts
  end

  # -- Secret refs ------------------------------------------------------------

  defp collect_secret_refs(request) do
    [request.headers, request.query, request.body, request.url]
    |> Enum.flat_map(&scan_refs/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scan_refs(value) when is_binary(value),
    do: @secret_placeholder |> Regex.scan(value) |> Enum.map(fn [_full, ref] -> ref end)

  defp scan_refs(value) when is_map(value),
    do: Enum.flat_map(value, fn {k, v} -> scan_refs(k) ++ scan_refs(v) end)

  defp scan_refs(value) when is_list(value), do: Enum.flat_map(value, &scan_refs/1)

  defp scan_refs(_value), do: []

  # -- Helpers ----------------------------------------------------------------

  defp method_atom(method), do: method |> String.downcase() |> String.to_existing_atom()

  # Nested maps arrive with string keys from JSON tool calls, but with atom keys
  # when a workflow step passes them directly.
  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
