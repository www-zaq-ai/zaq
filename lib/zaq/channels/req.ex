defmodule Zaq.Channels.Req do
  @moduledoc """
  Executes a prepared HTTP request spec with `Req`.

  This is the *execute* half of the pipeline whose *prepare* half is
  `Zaq.Agent.Tools.General.BuildHttpRequest`:

      build_http_request  (agent decides what to send)
        → NodeRouter :http_request → Zaq.Channels.Api
        → this module        (decides whether and how to send it)

  The split matters: the agent never opens a socket. Deciding which hosts are
  reachable happens here, on the channels node.

  ## Secret placeholders are not resolved yet

  `BuildHttpRequest` renders credentials as `{{secret:name}}` placeholders.
  **This module does not substitute them** — it sends the spec exactly as
  given, so a request carrying a placeholder goes out with the literal
  `{{secret:name}}` text and the remote API will reject it. Wiring resolution
  to a credential store is deliberately deferred; until then this executor is
  only useful for endpoints that need no authorization, or for callers that
  substitute values into the spec themselves before calling.

  ## Destination safety

  The URL comes from an LLM, so it is treated as untrusted input:

  - only `http` and `https` are accepted;
  - if `allowed_hosts` is configured, the host must match one of them
    (exact, or `.suffix` for a domain and its subdomains);
  - the host must not resolve to a loopback, private, link-local, or
    carrier-grade-NAT address — this blocks reaching internal services and
    cloud metadata endpoints (`169.254.169.254`) from a prompt;
  - redirects are **not** followed, since a redirect would otherwise bypass
    every check above.

  Set `allow_private_hosts: true` to reach on-prem internal APIs deliberately.

  ## Configuration

      config :zaq, Zaq.Channels.Req,
        allowed_hosts: ["api.acme.com", ".internal.acme.com"],
        allow_private_hosts: false,
        max_response_bytes: 100_000,
        timeout_ms: 30_000,
        req_options: []

  Every key is overridable per call through `opts`, which is how
  `Zaq.Channels.Api` forwards `Zaq.Event` options and how tests inject a
  `Req.Test` plug.

  ## Response

      {:ok, %{status: 201, success: true, headers: %{...}, body: ...,
              truncated: false, url: "https://..."}}

  `body` is truncated to `max_response_bytes` so a large response cannot flood
  the agent's context; `truncated` says whether that happened.

  > #### Response size {: .info}
  > The cap is applied after the body is received, not during transfer — it
  > bounds what reaches the agent, not what crosses the network.
  """

  import Bitwise

  @default_max_response_bytes 100_000
  @default_timeout_ms 30_000
  @redacted_response_headers ~w(set-cookie authorization proxy-authorization)

  @type response :: %{
          status: pos_integer(),
          success: boolean(),
          headers: %{String.t() => String.t()},
          body: term(),
          truncated: boolean(),
          url: String.t()
        }

  @doc """
  Performs the request described by `spec`.

  `spec` is the `:request` map produced by
  `Zaq.Agent.Tools.General.BuildHttpRequest` — `method`, `url`, `headers`,
  `query`, `body`, `body_format`. String keys are accepted so a spec that
  round-tripped through JSON still works.
  """
  @spec request(map(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    config = config(opts)

    with {:ok, spec} <- normalize(spec),
         :ok <- authorize_destination(spec.url, config) do
      perform(spec, config)
    end
  end

  # -- Config -----------------------------------------------------------------

  defp config(opts) do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(opts)
  end

  # -- Spec normalisation -----------------------------------------------------

  defp normalize(spec) do
    with {:ok, method} <- normalize_method(get(spec, :method)),
         {:ok, url} <- normalize_url(get(spec, :url)) do
      {:ok,
       %{
         method: method,
         url: url,
         headers: get(spec, :headers) || %{},
         query: get(spec, :query) || %{},
         body: get(spec, :body),
         body_format: get(spec, :body_format) || "json"
       }}
    end
  end

  defp normalize_method(method) when is_atom(method) and not is_nil(method), do: {:ok, method}

  defp normalize_method(method) when is_binary(method) do
    {:ok, method |> String.downcase() |> String.to_existing_atom()}
  rescue
    ArgumentError -> {:error, {:invalid_method, method}}
  end

  defp normalize_method(method), do: {:error, {:invalid_method, method}}

  defp normalize_url(url) when is_binary(url) and url != "", do: {:ok, url}
  defp normalize_url(url), do: {:error, {:invalid_url, url}}

  # -- Destination safety -----------------------------------------------------

  defp authorize_destination(url, config) do
    with {:ok, %URI{scheme: scheme, host: host}} <- parse_uri(url),
         :ok <- check_scheme(scheme, url),
         :ok <- check_host_present(host, url),
         :ok <- check_allowed_hosts(host, Keyword.get(config, :allowed_hosts, [])) do
      check_address(host, config)
    end
  end

  defp parse_uri(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, {:invalid_url, url}}
    end
  end

  defp check_scheme(scheme, _url) when scheme in ["http", "https"], do: :ok
  # No scheme at all means a relative reference, not a rejected protocol.
  defp check_scheme(nil, url), do: {:error, {:invalid_url, url}}
  defp check_scheme(_scheme, url), do: {:error, {:unsupported_scheme, url}}

  defp check_host_present(host, _url) when is_binary(host) and host != "", do: :ok
  defp check_host_present(_host, url), do: {:error, {:invalid_url, url}}

  defp check_allowed_hosts(_host, []), do: :ok
  defp check_allowed_hosts(_host, nil), do: :ok

  defp check_allowed_hosts(host, allowed) when is_list(allowed) do
    host = String.downcase(host)

    if Enum.any?(allowed, &host_matches?(host, String.downcase(&1))),
      do: :ok,
      else: {:error, {:host_not_allowed, host}}
  end

  defp host_matches?(host, "." <> _ = suffix), do: String.ends_with?(host, suffix)
  defp host_matches?(host, allowed), do: host == allowed

  # A literal IP is checked directly. A name is only resolved when the request
  # will really leave the node — with a `Req.Test` plug installed no socket is
  # opened, so DNS would just fail on fixture hostnames.
  defp check_address(host, config) do
    if Keyword.get(config, :allow_private_hosts, false) do
      :ok
    else
      host
      |> addresses(config)
      |> reject_private(host)
    end
  end

  defp addresses(host, config) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        if stubbed?(config), do: :skip, else: resolve(charlist)
    end
  end

  defp stubbed?(config) do
    config |> Keyword.get(:req_options, []) |> Keyword.has_key?(:plug)
  end

  defp resolve(charlist) do
    case {:inet.getaddrs(charlist, :inet), :inet.getaddrs(charlist, :inet6)} do
      {{:ok, v4}, {:ok, v6}} -> {:ok, v4 ++ v6}
      {{:ok, v4}, _} -> {:ok, v4}
      {_, {:ok, v6}} -> {:ok, v6}
      _ -> :unresolvable
    end
  end

  defp reject_private(:skip, _host), do: :ok
  defp reject_private(:unresolvable, host), do: {:error, {:unresolvable_host, host}}

  defp reject_private({:ok, addresses}, host) do
    if Enum.any?(addresses, &private_address?/1),
      do: {:error, {:private_host_not_allowed, host}},
      else: :ok
  end

  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({_, _, _, _}), do: false

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — check the embedded v4 address.
  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: private_address?({ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF})

  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # fc00::/7 unique-local and fe80::/10 link-local
  defp private_address?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true
  defp private_address?({_, _, _, _, _, _, _, _}), do: false
  defp private_address?(_address), do: true

  # -- Execution --------------------------------------------------------------

  defp perform(spec, config) do
    max_bytes = Keyword.get(config, :max_response_bytes, @default_max_response_bytes)

    spec
    |> req_options(config)
    |> Req.request()
    |> handle_response(spec, max_bytes)
  end

  defp req_options(spec, config) do
    base = [
      method: spec.method,
      url: spec.url,
      headers: spec.headers,
      receive_timeout: Keyword.get(config, :timeout_ms, @default_timeout_ms),
      redirect: false,
      retry: false
    ]

    base
    |> maybe_put(:params, spec.query, &(is_map(&1) and map_size(&1) > 0))
    |> maybe_put(body_key(spec.body_format), spec.body, &(not is_nil(&1)))
    |> Keyword.merge(Keyword.get(config, :req_options, []))
  end

  defp body_key("form"), do: :form
  defp body_key("raw"), do: :body
  defp body_key(_json), do: :json

  defp maybe_put(opts, key, value, keep?) do
    if keep?.(value), do: opts ++ [{key, value}], else: opts
  end

  defp handle_response({:ok, %Req.Response{} = response}, spec, max) do
    {body, truncated} = cap_body(response.body, max)

    {:ok,
     %{
       status: response.status,
       success: response.status in 200..299,
       headers: safe_headers(response.headers),
       body: body,
       truncated: truncated,
       url: spec.url
     }}
  end

  defp handle_response({:error, %{__exception__: true} = exception}, _spec, _max),
    do: {:error, {:transport_error, Exception.message(exception)}}

  defp handle_response({:error, reason}, _spec, _max), do: {:error, {:transport_error, reason}}

  defp cap_body(body, max) when is_binary(body) do
    if byte_size(body) > max, do: {binary_part(body, 0, max), true}, else: {body, false}
  end

  defp cap_body(body, max) when is_map(body) or is_list(body) do
    case Jason.encode(body) do
      {:ok, encoded} when byte_size(encoded) > max -> {binary_part(encoded, 0, max), true}
      _ -> {body, false}
    end
  end

  defp cap_body(body, _max), do: {body, false}

  defp safe_headers(headers) when is_map(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(name) in @redacted_response_headers end)
    |> Map.new(fn {name, value} -> {String.downcase(name), join_header(value)} end)
  end

  defp safe_headers(_headers), do: %{}

  defp join_header(value) when is_list(value), do: Enum.join(value, ", ")
  defp join_header(value) when is_binary(value), do: value
  defp join_header(value), do: to_string(value)

  # -- Helpers ----------------------------------------------------------------

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
