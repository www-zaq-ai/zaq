defmodule Zaq.Channels.HttpClient do
  @moduledoc """
  Sends outbound HTTP requests over the network after authoritative policy checks.

  This is the far side of the `:http_request` hop:

      http_request tool  (agent decides what to send, and validates it)
        → NodeRouter :http_request → Zaq.Channels.Api
        → this module        (resolves credentials, opens the socket)

  The split matters: the agent never opens a socket and never holds a token.

  > #### Not the `Req` library {: .info}
  > This module wraps `Req`; it is not a rename of it. It owns credential
  > resolution, response truncation, and header redaction — none of which the
  > library does. It was called `Zaq.Channels.Req` until that name kept
  > reading as the dependency.

  ## Boundary validation

  This module treats both maps and `%Zaq.HttpRequest{}` structs as untrusted
  input. It reruns shared validation, resolves DNS on the channels node, and
  checks every resolved address before opening a socket.

  Redirects are **not** followed yet: a redirect would send the request to a
  host that never passed destination validation.

  ## Credentials

  Requests carry only `credential_id`. Auth Credentials and dynamic HTTP
  provider placement rules are resolved here, immediately before `Req.request/1`,
  so plaintext secrets never cross the agent boundary or appear in responses.

  ## Configuration

      config :zaq, Zaq.Channels.HttpClient,
        req_options: []

  `req_options` is a test seam for plugs/adapters. Production calls through
  `Zaq.Channels.Api` do not forward untrusted event options into this module.

  ## Response

      {:ok, %{status: 201, success: true, headers: %{...}, body: ...,
              truncated: false, url: "https://..."}}

  `body` is truncated to `max_response_bytes` so a large response cannot flood
  the agent's context; `truncated` says whether that happened.

  > #### Response size {: .info}
  > The cap is applied after the body is received, not during transfer — it
  > bounds what reaches the agent, not what crosses the network.
  """

  alias Zaq.Channels.HttpClient.CredentialInjector
  alias Zaq.Config
  alias Zaq.HttpRequest
  alias Zaq.HttpRequest.{AddressPolicy, Validator}
  alias Zaq.System
  alias Zaq.System.OutboundHttpPolicy

  @default_max_response_bytes 100_000
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
  Sends `request`.

  Only a `%Zaq.HttpRequest{}` is accepted — see the module note on why
  a map is refused instead of normalised.

  `opts` are accepted only for direct test seams; production event options are
  never forwarded here.
  """
  @spec request(HttpRequest.t() | map(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(request, opts \\ [])

  def request(%HttpRequest{} = request, opts) when is_list(opts),
    do: request(HttpRequest.to_map(request), opts)

  def request(spec, opts) when is_map(spec) and is_list(opts),
    do: perform(spec, config(opts))

  # -- Config -----------------------------------------------------------------

  defp config(opts) do
    Config.get(:zaq, __MODULE__, [], opts)
  end

  # -- Execution --------------------------------------------------------------

  defp perform(request, config) do
    policy = Keyword.get_lazy(config, :policy, &System.get_outbound_http_policy/0)

    with {:ok, request} <- Validator.validate(request, policy),
         :ok <- validate_destination_addresses(request.uri.host, policy, config) do
      max_bytes = policy.max_response_bytes || @default_max_response_bytes

      with {:ok, req_options} <-
             request |> req_options(config) |> CredentialInjector.inject(request, config) do
        req_options
        |> Req.request()
        |> handle_response(request, max_bytes)
      end
    end
  end

  # The spec contributes what to send; this module contributes transport policy.
  # The timeout comes from the spec, never from config — every `HttpRequest`
  # carries one, so a config fallback here could never be reached.
  defp req_options(request, config) do
    transport = [receive_timeout: request.timeout_ms, redirect: false, retry: false]

    request_options = [
      method: String.downcase(request.method) |> String.to_atom(),
      url: request.url,
      headers: request.headers
    ]

    test_req_options(config)
    |> Keyword.merge(request_options)
    |> maybe_put(:params, request.query, &(is_map(&1) and map_size(&1) > 0))
    |> maybe_put(body_key(request.body_format), request.body, &(not is_nil(&1)))
    |> Keyword.merge(transport)
  end

  defp validate_destination_addresses(host, %OutboundHttpPolicy{} = policy, config) do
    case AddressPolicy.parse_ip(host) do
      {:ok, ip} ->
        AddressPolicy.validate(ip, policy)

      {:error, :invalid_ip} ->
        host
        |> resolve_host(config)
        |> validate_resolved_addresses(policy)
    end
  end

  defp resolve_host(host, config) do
    resolver = Keyword.get(config, :resolver, &:inet.getaddrs/2)
    resolver.(String.to_charlist(host), :inet)
  end

  defp validate_resolved_addresses({:ok, []}, _policy),
    do: {:error, :dns_failed, "host resolved to no addresses"}

  defp validate_resolved_addresses({:ok, addresses}, policy) do
    Enum.reduce_while(addresses, :ok, fn address, :ok ->
      case AddressPolicy.validate(address, policy) do
        :ok -> {:cont, :ok}
        {:error, _reason, _message} = error -> {:halt, error}
      end
    end)
  end

  defp validate_resolved_addresses({:error, _reason}, _policy),
    do: {:error, :dns_failed, "could not resolve host"}

  defp test_req_options(config), do: Keyword.get(config, :req_options, [])

  defp maybe_put(opts, key, value, predicate) do
    if predicate.(value), do: Keyword.put(opts, key, value), else: opts
  end

  defp body_key("json"), do: :json
  defp body_key("form"), do: :form
  defp body_key("raw"), do: :body

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

  # `Req.request/1` is specced to return an exception on failure, so there is no
  # second clause for a bare term — a contract break should crash loudly rather
  # than be silently reshaped into a transport error.
  defp handle_response({:error, exception}, _spec, _max),
    do: {:error, {:transport_error, Exception.message(exception)}}

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

  # Req always builds `headers` as a map; a non-map would already have crashed
  # inside its own response steps, so there is no fallback clause here.
  defp safe_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(name) in @redacted_response_headers end)
    |> Map.new(fn {name, value} -> {String.downcase(name), join_header(value)} end)
  end

  defp join_header(value) when is_list(value), do: Enum.join(value, ", ")
  defp join_header(value) when is_binary(value), do: value
  defp join_header(value), do: to_string(value)
end
