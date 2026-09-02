defmodule Zaq.HttpRequest.Validator do
  @moduledoc """
  Shared structural and policy validation for outbound HTTP requests.

  This module performs the checks that can run without network I/O. Channels
  must still run authoritative DNS/address validation immediately before
  transport.
  """

  alias Zaq.HttpRequest.HostMatcher
  alias Zaq.System.HttpCredentialProviderRef
  alias Zaq.System.OutboundHttpPolicy

  @bodyless_methods ~w(GET HEAD OPTIONS DELETE)
  @default_timeout_ms 30_000

  @type normalized :: %{
          method: String.t(),
          url: String.t(),
          uri: URI.t(),
          headers: %{String.t() => String.t()},
          query: %{String.t() => String.t()},
          body: term(),
          body_format: String.t(),
          timeout_ms: pos_integer(),
          doc_reference: String.t(),
          credential_id: pos_integer() | nil
        }

  @doc "Validates request params with structural and non-DNS policy checks."
  @spec validate(map(), OutboundHttpPolicy.t()) ::
          {:ok, normalized()} | {:error, atom(), String.t()}
  def validate(params, %OutboundHttpPolicy{} = policy) when is_map(params) do
    with :ok <- ensure_enabled(policy),
         {:ok, method} <- validate_method(fetch(params, :method), policy),
         {:ok, uri} <- validate_url(fetch(params, :url)),
         :ok <- validate_port(uri, policy),
         :ok <- validate_host_blacklist(uri.host, policy),
         {:ok, headers} <- normalize_headers(fetch(params, :headers)),
         {:ok, query} <- normalize_query(fetch(params, :query)),
         {:ok, format} <- validate_body_format(fetch(params, :body_format) || "json"),
         {:ok, body} <- validate_body(method, fetch(params, :body), format),
         {:ok, timeout_ms} <- validate_timeout(fetch(params, :timeout_ms), policy),
         {:ok, credential_id} <- validate_credential_id(fetch(params, :credential_id)) do
      {:ok,
       %{
         method: method,
         url: URI.to_string(uri),
         uri: uri,
         headers: headers,
         query: query,
         body: body,
         body_format: format,
         timeout_ms: timeout_ms,
         doc_reference: to_string(fetch(params, :doc_reference) || ""),
         credential_id: credential_id
       }}
    end
  end

  def validate(_params, _policy), do: {:error, :invalid_request, "request must be a map"}

  defp ensure_enabled(%OutboundHttpPolicy{enabled: true}), do: :ok

  defp ensure_enabled(%OutboundHttpPolicy{}),
    do: {:error, :disabled, "outbound HTTP requests are disabled by policy"}

  defp validate_method(method, policy) when is_binary(method) do
    method = method |> String.trim() |> String.upcase()

    cond do
      method == "" ->
        {:error, :invalid_method, "method is required"}

      method not in OutboundHttpPolicy.supported_methods() ->
        {:error, :invalid_method, "method is not supported"}

      method not in policy.allowed_methods ->
        {:error, :method_not_allowed, "method #{method} is not allowed by outbound HTTP policy"}

      true ->
        {:ok, method}
    end
  end

  defp validate_method(_method, _policy), do: {:error, :invalid_method, "method must be a string"}

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_url(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        cond do
          uri.query not in [nil, ""] ->
            {:error, :invalid_url, "url must not carry a query string"}

          uri.fragment not in [nil, ""] ->
            {:error, :invalid_url, "url must not carry a fragment"}

          true ->
            {:ok, %{uri | host: String.downcase(host)}}
        end

      {:ok, %URI{userinfo: userinfo}} when is_binary(userinfo) ->
        {:error, :invalid_url, "url must not contain userinfo"}

      {:ok, _uri} ->
        {:error, :invalid_url, "url must be an absolute http:// or https:// URL with a host"}

      {:error, _part} ->
        {:error, :invalid_url, "url is not a valid URI"}
    end
  end

  defp validate_url(_url), do: {:error, :invalid_url, "url must be a string"}

  defp validate_port(%URI{port: nil}, _policy), do: :ok
  defp validate_port(_uri, %OutboundHttpPolicy{allowed_ports: []}), do: :ok

  defp validate_port(%URI{port: port}, %OutboundHttpPolicy{allowed_ports: ports}) do
    if port in ports, do: :ok, else: {:error, :port_not_allowed, "port #{port} is not allowed"}
  end

  defp validate_host_blacklist(host, %OutboundHttpPolicy{blacklisted_hosts: hosts}) do
    host = String.downcase(host)

    if Enum.any?(hosts, &HostMatcher.matches?(host, &1)),
      do: {:error, :host_blacklisted, "host #{host} is blacklisted"},
      else: :ok
  end

  defp normalize_headers(nil), do: {:ok, %{}}

  defp normalize_headers(headers) when is_map(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      name = name |> to_string() |> String.trim() |> String.downcase()

      cond do
        name == "" ->
          {:halt, {:error, :invalid_headers, "header names must not be blank"}}

        not is_binary(value) ->
          {:halt, {:error, :invalid_headers, "header #{name} must be a string"}}

        name in ["authorization", "proxy-authorization"] ->
          {:halt,
           {:error, :credential_not_allowed, "literal authorization headers are not allowed"}}

        true ->
          {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp normalize_headers(_headers), do: {:error, :invalid_headers, "headers must be a map"}

  defp normalize_query(nil), do: {:ok, %{}}

  defp normalize_query(query) when is_map(query) do
    Enum.reduce_while(query, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if is_binary(value) or is_number(value) or is_boolean(value) do
        {:cont, {:ok, Map.put(acc, to_string(key), to_string(value))}}
      else
        {:halt, {:error, :invalid_query, "query values must be strings, numbers, or booleans"}}
      end
    end)
  end

  defp normalize_query(_query), do: {:error, :invalid_query, "query must be a map"}

  defp validate_body_format(format) when format in ["json", "form", "raw"], do: {:ok, format}

  defp validate_body_format(_format),
    do: {:error, :invalid_body, "body_format must be json, form, or raw"}

  defp validate_body(method, body, _format)
       when method in @bodyless_methods and body not in [nil, "", %{}, []],
       do: {:error, :invalid_body, "#{method} requests must not carry a body"}

  defp validate_body(_method, nil, _format), do: {:ok, nil}
  defp validate_body(_method, "", _format), do: {:ok, nil}
  defp validate_body(_method, body, "json") when is_map(body) or is_list(body), do: {:ok, body}
  defp validate_body(_method, body, "form") when is_map(body), do: {:ok, body}
  defp validate_body(_method, body, "raw") when is_binary(body), do: {:ok, body}

  defp validate_body(_method, _body, _format),
    do: {:error, :invalid_body, "body shape does not match body_format"}

  defp validate_timeout(nil, %OutboundHttpPolicy{max_timeout_ms: max}),
    do: {:ok, min(@default_timeout_ms, max)}

  defp validate_timeout(timeout, %OutboundHttpPolicy{max_timeout_ms: max})
       when is_integer(timeout) and timeout > 0 do
    if timeout <= max,
      do: {:ok, timeout},
      else: {:error, :timeout_too_large, "timeout exceeds outbound HTTP policy limit"}
  end

  defp validate_timeout(_timeout, _policy),
    do: {:error, :invalid_timeout, "timeout_ms must be a positive integer"}

  defp validate_credential_id(nil), do: {:ok, nil}
  defp validate_credential_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp validate_credential_id(id) when is_binary(id) do
    case HttpCredentialProviderRef.parse_id_for_validator(id) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> {:error, :invalid_credential_ref, "credential_id must be a positive integer"}
    end
  end

  defp validate_credential_id(_id),
    do: {:error, :invalid_credential_ref, "credential_id must be a positive integer"}

  defp fetch(params, key), do: Map.get(params, key) || Map.get(params, to_string(key))
end
