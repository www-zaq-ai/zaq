defmodule Zaq.Channels.HttpClient do
  @moduledoc """
  Sends a validated `Zaq.Channels.HttpRequest` over the network.

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

  ## This module validates nothing

  It accepts `%Zaq.Channels.HttpRequest{}` and nothing else. That struct can
  only be produced by `HttpRequest.build/2`, so receiving one *is* the proof
  that the URL, headers, query, body, and destination allowlist were all
  checked. A bare map — however well-formed — is refused with
  `{:invalid_request, :unvalidated_spec}` rather than being re-checked here.

  Redirects are **not** followed: a redirect would send the request to a host
  that never passed the allowlist.

  ## No credentials

  Requests carry no authorization: `HttpRequest.build/2` rejects credential
  headers outright, so there is nothing here to resolve, redact on the way out,
  or keep out of a log. See `Zaq.Channels.HttpRequest` for why.

  ## Configuration

      config :zaq, Zaq.Channels.HttpClient,
        max_response_bytes: 100_000,
        req_options: []

  Both keys are overridable per call through `opts`, which is how
  `Zaq.Channels.Api` forwards `Zaq.Event` options and how tests inject a
  `Req.Test` plug.

  Two things are deliberately **not** configured here: destination policy
  (`allowed_hosts`) belongs to `Zaq.Channels.HttpRequest`, where it is enforced,
  and the receive timeout travels on the request struct.

  ## Response

      {:ok, %{status: 201, success: true, headers: %{...}, body: ...,
              truncated: false, url: "https://..."}}

  `body` is truncated to `max_response_bytes` so a large response cannot flood
  the agent's context; `truncated` says whether that happened.

  > #### Response size {: .info}
  > The cap is applied after the body is received, not during transfer — it
  > bounds what reaches the agent, not what crosses the network.
  """

  alias Zaq.Channels.HttpRequest

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

  Only a `%Zaq.Channels.HttpRequest{}` is accepted — see the module note on why
  a map is refused instead of normalised.

  `opts` may override `:max_response_bytes` and `:req_options`.
  """
  @spec request(HttpRequest.t() | map(), keyword()) :: {:ok, response()} | {:error, term()}
  def request(request, opts \\ [])

  def request(%HttpRequest{} = request, opts) when is_list(opts),
    do: perform(request, config(opts))

  def request(spec, _opts) when is_map(spec),
    do: {:error, {:invalid_request, :unvalidated_spec}}

  # -- Config -----------------------------------------------------------------

  defp config(opts) do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(opts)
  end

  # -- Execution --------------------------------------------------------------

  defp perform(request, config) do
    max_bytes = Keyword.get(config, :max_response_bytes, @default_max_response_bytes)

    request
    |> req_options(config)
    |> Req.request()
    |> handle_response(request, max_bytes)
  end

  # The spec contributes what to send; this module contributes transport policy.
  # The timeout comes from the spec, never from config — every `HttpRequest`
  # carries one, so a config fallback here could never be reached.
  defp req_options(request, config) do
    transport = [receive_timeout: request.timeout_ms, redirect: false, retry: false]

    request
    |> HttpRequest.to_req_options()
    |> Keyword.merge(transport)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
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
