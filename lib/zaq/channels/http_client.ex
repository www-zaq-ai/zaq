defmodule Zaq.Channels.HttpClient do
  @moduledoc """
  Sends outbound HTTP requests over the network after authoritative policy checks.

  This is the far side of the `:http_request` hop:

      http_request tool  (agent decides what to send, and validates it)
        → NodeRouter :http_request → Zaq.Channels.Api
        → Engine prepare  (loads policy and credentials)
        → this module     (checks addresses, opens the socket)

  The split matters: the agent never opens a socket and never holds a token.

  > #### Not the `Req` library {: .info}
  > This module wraps `Req`; it is not a rename of it. It owns credential
  > resolution, response truncation, and header redaction — none of which the
  > library does. It was called `Zaq.Channels.Req` until that name kept
  > reading as the dependency.

  ## Boundary validation

  This module accepts only `%Zaq.HttpRequest.Prepared{}` values returned by
  Engine. It resolves DNS on the channels node and checks every resolved
  address before opening a socket.

  Redirects are **not** followed yet: a redirect would send the request to a
  host that never passed destination validation.

  ## Credentials

  Requests carry only Engine-rendered credential material. Auth Credentials and
  dynamic HTTP provider placement rules are loaded by Engine so Channels remains
  stateless and database-free.

  ## Response

      {:ok, %{status: 201, success: true, headers: %{...}, body: ...,
              truncated: false, url: "https://..."}}

  The default `response_format: "decoded"` applies `max_response_bytes` after
  reception and retains the decoded body or a truncated prefix. Header values
  are joined with commas.

  `response_format: "raw"` bounds reception by counting entity bytes, after HTTP
  transfer framing and before content decoding or decompression. Crossing the
  limit stops reception with `{:error, :response_too_large}`, never a truncated
  success. Complete bodies are Base64 strings with `body_encoding: "base64"`;
  Base64 expansion and metadata are outside the entity-byte limit. Raw header
  values remain lists, including duplicate signing metadata and `content-encoding`.
  Raw responses return trailers separately, with the same filtering and UTF-8
  validation as headers; absent trailers are an empty map. Both modes filter
  credential/cookie response headers.

  Finch 0.24.0 misclassifies trailers on empty, chunked HTTP/1.1 entities, allowing
  Req to overwrite initial headers and leave trailers empty. That response shape
  is not metadata-safe until [Finch #408](https://github.com/sneako/finch/issues/408)
  is fixed and the dependency updated (`zaq-bjp`). HTTP/2 trailers and non-empty
  HTTP/1.1 entities with trailers are unaffected.

  Raw requests send `accept-encoding: identity`. A peer may still send encoded
  content; its bytes and encoding header are returned unchanged. The caller owns
  signature verification and protocol interpretation.
  """

  alias Zaq.HttpRequest.{AddressPolicy, Prepared}
  alias Zaq.System.OutboundHttpPolicy

  @default_max_response_bytes 100_000
  @redacted_response_headers ~w(set-cookie authorization proxy-authorization)

  @type response :: %{
          optional(:body_encoding) => String.t(),
          optional(:trailers) => %{String.t() => [String.t()]},
          status: pos_integer(),
          success: boolean(),
          headers: %{String.t() => String.t() | [String.t()]},
          body: term(),
          truncated: boolean(),
          url: String.t()
        }

  @doc """
  Sends `request`.

  Only a `%Zaq.HttpRequest.Prepared{}` is accepted.
  """
  @spec request(Prepared.t() | term()) :: {:ok, response()} | {:error, term()}
  def request(request)

  def request(%Prepared{} = prepared), do: perform(prepared)

  def request(_request),
    do: {:error, :unprepared_request, "request was not prepared by Engine"}

  # -- Execution --------------------------------------------------------------

  defp perform(%Prepared{policy: policy} = request) do
    with :ok <- validate_destination_addresses(request.uri.host, policy) do
      max_bytes = policy.max_response_bytes || @default_max_response_bytes

      request
      |> request_options()
      |> response_options(request.response_format, max_bytes)
      |> Req.request()
      |> handle_response(request, max_bytes)
    end
  end

  # The prepared request contributes what to send; this module adds fixed
  # transport safety options.
  defp request_options(request) do
    transport = [receive_timeout: request.timeout_ms, redirect: false, retry: false]

    request_options = [
      method: String.downcase(request.method) |> String.to_atom(),
      url: request.url,
      headers: request.headers
    ]

    request_options
    |> maybe_put(:params, request.query, &(is_map(&1) and map_size(&1) > 0))
    |> maybe_put(body_key(request.body_format), request.body, &(not is_nil(&1)))
    |> merge_credential(request.credential)
    |> Keyword.merge(transport)
  end

  defp merge_credential(request_options, nil), do: request_options

  defp merge_credential(request_options, {:header, name, value}) do
    Keyword.update(request_options, :headers, %{name => value}, &Map.put(&1, name, value))
  end

  defp merge_credential(request_options, {:auth, auth}),
    do: Keyword.put(request_options, :auth, auth)

  defp merge_credential(request_options, {:query, name, value}) do
    Keyword.update(request_options, :params, %{name => value}, &Map.put(&1, name, value))
  end

  defp response_options(options, "decoded", _max_bytes), do: options

  defp response_options(options, "raw", max_bytes) do
    options
    |> Keyword.update!(:headers, &Map.put(&1, "accept-encoding", "identity"))
    |> Keyword.put(:raw, true)
    |> Keyword.put(:into, fn
      {:data, ""}, acc ->
        {:cont, acc}

      {:data, chunk}, {request, response} ->
        received_bytes = Map.get(response.private, :zaq_received_bytes, 0) + byte_size(chunk)

        if received_bytes > max_bytes do
          {:halt, {request, %{response | body: :response_too_large}}}
        else
          response =
            response
            |> Map.put(:body, [chunk | List.wrap(response.body)])
            |> Req.Response.put_private(:zaq_received_bytes, received_bytes)

          {:cont, {request, response}}
        end
    end)
  end

  defp validate_destination_addresses(host, %OutboundHttpPolicy{} = policy) do
    case AddressPolicy.parse_ip(host) do
      {:ok, ip} ->
        AddressPolicy.validate(ip, policy)

      {:error, :invalid_ip} ->
        host
        |> resolve_host()
        |> validate_resolved_addresses(policy)
    end
  end

  defp resolve_host(host), do: :inet.getaddrs(String.to_charlist(host), :inet)

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

  defp maybe_put(opts, key, value, predicate) do
    if predicate.(value), do: Keyword.put(opts, key, value), else: opts
  end

  defp body_key("json"), do: :json
  defp body_key("form"), do: :form
  defp body_key("raw"), do: :body

  defp handle_response(
         {:ok, %Req.Response{body: :response_too_large}},
         %Prepared{response_format: "raw"},
         _max
       ),
       do: {:error, :response_too_large}

  defp handle_response(
         {:ok, %Req.Response{} = response},
         %Prepared{response_format: "raw"} = spec,
         _max
       ) do
    with {:ok, headers} <- raw_headers(response.headers),
         {:ok, trailers} <- raw_headers(response.trailers) do
      body = response.body |> List.wrap() |> Enum.reverse() |> IO.iodata_to_binary()

      {:ok,
       %{
         status: response.status,
         success: response.status in 200..299,
         headers: headers,
         trailers: trailers,
         body: Base.encode64(body),
         body_encoding: "base64",
         truncated: false,
         url: spec.url
       }}
    end
  end

  defp handle_response({:ok, %Req.Response{} = response}, spec, max) do
    {body, truncated} = cap_body(response.body, max)

    {:ok,
     %{
       status: response.status,
       success: response.status in 200..299,
       headers: safe_headers(response.headers, "decoded"),
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

  defp raw_headers(headers) do
    headers = safe_headers(headers, "raw")

    if Enum.all?(headers, fn {name, values} ->
         String.valid?(name) and Enum.all?(values, &String.valid?/1)
       end),
       do: {:ok, headers},
       else: {:error, :invalid_response_headers}
  end

  # Req always builds `headers` as a map; a non-map would already have crashed
  # inside its own response steps, so there is no fallback clause here.
  defp safe_headers(headers, format) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(name) in @redacted_response_headers end)
    |> Map.new(fn {name, value} ->
      value = if format == "raw", do: List.wrap(value), else: join_header(value)
      {String.downcase(name), value}
    end)
  end

  defp join_header(value) when is_list(value), do: Enum.join(value, ", ")
  defp join_header(value) when is_binary(value), do: value
  defp join_header(value), do: to_string(value)
end
