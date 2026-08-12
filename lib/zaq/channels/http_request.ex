defmodule Zaq.Channels.HttpRequest do
  @moduledoc """
  A validated outbound HTTP request spec.

  This struct is the boundary type between *deciding what to send* and
  *sending it*. `Zaq.Channels.HttpClient` accepts nothing else, so the struct's
  existence is the proof that validation ran — which is why the client performs
  no checks of its own.

      http_request tool  →  %HttpRequest{}  →  Zaq.Channels.HttpClient
       (all validation)       (the proof)         (send only)

  Every shape rule lives in `build/2`: URL form, header and query shape,
  body/format agreement, and the destination allowlist. A bare map can never
  reach the client, so nothing is checked twice.

  ## Credentials are not supported

  There is no way to authenticate a request through this struct, and that is
  deliberate rather than unfinished. A literal `authorization` or
  `proxy-authorization` header is **rejected**: the request originates from an
  LLM tool call, so any credential passed as a parameter would enter the
  model's context and be persisted in conversation history and every transcript
  export of it.

  This limits the path to endpoints that need no authorization. Supporting
  authenticated calls needs a mechanism that keeps the value off the agent node
  entirely — a named reference resolved on the channels node, not a header the
  model can write.

  ## Destination safety

  The URL comes from an LLM, so it is treated as untrusted input:

  - only `http` and `https` are accepted, and a host is required;
  - if `allowed_hosts` is configured, the host must match one of them
    (exact, or `.suffix` for a domain and its subdomains).

  > #### Private-address blocking is not implemented {: .warning}
  > Resolving a host to check it against loopback, private, link-local, and
  > carrier-grade-NAT ranges is DNS I/O, and it was removed rather than run on
  > the wrong node. Until it is reinstated, **an `allowed_hosts` allowlist is
  > the only defence against reaching an internal service or a cloud metadata
  > endpoint (`169.254.169.254`) from a prompt.** Configure one in any
  > deployment where the agent can be prompted by an untrusted party.

  ## Configuration

      config :zaq, Zaq.Channels.HttpRequest,
        allowed_hosts: ["api.acme.com", ".internal.acme.com"]

  Overridable per call through `opts`.
  """

  @bodyless_methods ~w(GET DELETE)
  @default_timeout_ms 30_000

  @type t :: %__MODULE__{
          method: atom(),
          url: String.t(),
          headers: %{String.t() => String.t()},
          query: %{String.t() => String.t()},
          body: term(),
          body_format: String.t(),
          timeout_ms: pos_integer(),
          doc_reference: String.t()
        }

  defstruct method: :get,
            url: nil,
            headers: %{},
            query: %{},
            body: nil,
            body_format: "json",
            timeout_ms: @default_timeout_ms,
            doc_reference: ""

  @doc """
  Validates `params` and returns the request spec.

  `params` is the `http_request` tool parameter map: `method`, `url`,
  `headers`, `query`, `body`, `body_format`, `timeout_ms`, and
  `doc_reference`. Errors are returned as sentences addressed to the model,
  since they are fed back to it as the tool result.
  """
  @spec build(map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, url} <- validate_url(fetch(params, :url)),
         :ok <- check_allowed_hosts(url, opts),
         {:ok, raw_headers} <- ensure_map(fetch(params, :headers), "headers"),
         {:ok, raw_query} <- ensure_map(fetch(params, :query), "query"),
         {:ok, headers} <- normalize_headers(raw_headers),
         {:ok, query} <- normalize_query(raw_query),
         {:ok, method} <- validate_method(fetch(params, :method)),
         {:ok, format} <- validate_body_format(fetch(params, :body_format) || "json"),
         {:ok, body} <- validate_body(fetch(params, :method), fetch(params, :body), format) do
      {:ok,
       %__MODULE__{
         method: method,
         url: url,
         headers: headers,
         query: query,
         body: body,
         body_format: format,
         timeout_ms: fetch(params, :timeout_ms) || @default_timeout_ms,
         doc_reference: fetch(params, :doc_reference) || ""
       }}
    end
  end

  @doc """
  The spec as options for `Req.request/1`.

  Covers only what the spec itself determines — the executor adds transport
  policy (timeout, redirect, retry) and any configured overrides.
  """
  @spec to_req_options(t()) :: keyword()
  def to_req_options(%__MODULE__{} = request) do
    [method: request.method, url: request.url, headers: request.headers]
    |> maybe_put(:params, request.query, &(is_map(&1) and map_size(&1) > 0))
    |> maybe_put(body_key(request.body_format), request.body, &(not is_nil(&1)))
  end

  defp ensure_map(nil, _field), do: {:ok, %{}}
  defp ensure_map(value, _field) when is_map(value), do: {:ok, value}

  defp ensure_map(value, field),
    do: {:error, "#{field} must be a map of keys to values, got: #{inspect(value)}"}

  # -- Method -----------------------------------------------------------------

  defp validate_method(method) when method in ~w(GET POST PUT PATCH DELETE),
    do: {:ok, method |> String.downcase() |> String.to_existing_atom()}

  defp validate_method(method),
    do: {:error, "method must be one of GET, POST, PUT, PATCH, DELETE, got: #{inspect(method)}"}

  # -- URL --------------------------------------------------------------------

  defp validate_url(url) when is_binary(url) do
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

  defp validate_url(url), do: {:error, "url must be a string, got: #{inspect(url)}"}

  # -- Destination safety -----------------------------------------------------

  defp check_allowed_hosts(url, opts) do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(opts)
    |> Keyword.get(:allowed_hosts, [])
    |> allow?(URI.parse(url).host)
  end

  defp allow?(allowed, _host) when allowed in [[], nil], do: :ok

  defp allow?(allowed, host) when is_list(allowed) do
    host = String.downcase(host)

    if Enum.any?(allowed, &host_matches?(host, String.downcase(&1))),
      do: :ok,
      else: {:error, "host #{host} is not in the configured allowlist for outbound requests"}
  end

  defp host_matches?(host, "." <> _ = suffix), do: String.ends_with?(host, suffix)
  defp host_matches?(host, allowed), do: host == allowed

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
            "do not pass #{name} as a header — this tool cannot authenticate, and a " <>
              "credential passed here would be stored in the conversation history. " <>
              "Use it only for endpoints that need no authorization"}}

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

  # -- Body -------------------------------------------------------------------

  defp validate_body_format(format) when format in ~w(json form raw), do: {:ok, format}

  defp validate_body_format(format),
    do: {:error, ~s|body_format must be "json", "form", or "raw", got: #{inspect(format)}|}

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

  defp body_key("form"), do: :form
  defp body_key("raw"), do: :body
  defp body_key(_json), do: :json

  defp maybe_put(opts, key, value, keep?) do
    if keep?.(value), do: opts ++ [{key, value}], else: opts
  end

  # -- Helpers ----------------------------------------------------------------

  defp fetch(map, key), do: Map.get(map, key)
end
