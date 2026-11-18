defmodule Zaq.Channels.HttpClient.Connection do
  @moduledoc """
  Executes one synchronous Mint connection to an approved numeric peer.

  The request worker owns the socket throughout connection, TLS verification and
  response consumption. The logical hostname remains the HTTP authority and TLS
  identity. No asynchronous pool can retry establishment or replace its settings.
  Req still handles request encoding and the completed response pipeline.

  `[:zaq, :channels, :http_client, :connect, :start]` identifies the socket-owning
  worker before establishment. Its metadata contains only the destination port.
  """

  @doc "Connects once and consumes a response, closing the socket on every return path."
  @spec request(Req.Request.t(), :inet.ip_address(), integer(), :atomics.atomics_ref()) ::
          Req.Response.t() | Exception.t()
  def request(request, address, deadline, flags) do
    with :ok <- within_deadline(deadline, flags),
         :ok <- notify_connect(request),
         :ok <- within_deadline(deadline, flags),
         {:ok, conn} <- connect(request, address, deadline) do
      try do
        send_request(conn, request, deadline, flags)
      after
        Mint.HTTP.close(conn)
      end
    else
      {:error, error} -> normalize_error(error)
    end
  end

  defp notify_connect(request) do
    :telemetry.execute(
      [:zaq, :channels, :http_client, :connect, :start],
      %{system_time: System.system_time()},
      %{port: request.url.port}
    )
  end

  defp connect(request, address, deadline) do
    options = Map.get(request.options, :connect_options, [])

    family =
      if tuple_size(address) == 8,
        do: [inet6: true, inet4: false],
        else: [inet6: false, inet4: true]

    transport =
      options
      |> Keyword.get(:transport_opts, [])
      |> Keyword.merge(family)
      |> Keyword.put(:timeout, max(deadline - now(), 0))
      |> tls_identity(request.url)

    connection =
      options
      |> Keyword.take([:protocols, :client_settings])
      |> Keyword.put_new(:protocols, [:http1])
      |> Keyword.merge(hostname: request.url.host, mode: :passive, transport_opts: transport)

    scheme = if request.url.scheme == "https", do: :https, else: :http
    Mint.HTTP.connect(scheme, address, request.url.port, connection)
  end

  defp send_request(conn, request, deadline, flags) do
    case within_deadline(deadline, flags) do
      :ok ->
        request = Req.Request.put_header(request, "host", authority(request.url))
        path = if request.url.path in [nil, ""], do: "/", else: request.url.path
        target = if request.url.query, do: path <> "?" <> request.url.query, else: path
        method = request.method |> Atom.to_string() |> String.upcase()
        :atomics.put(flags, 1, 1)

        case Mint.HTTP.request(
               conn,
               method,
               target,
               Req.Fields.get_list(request.headers),
               request.body
             ) do
          {:ok, conn, ref} ->
            receive_response(
              conn,
              ref,
              {request, Req.Response.new(body: []), false},
              Map.get(request.options, :receive_timeout, 15_000)
            )

          {:error, _conn, error} ->
            normalize_error(error)
        end

      {:error, error} ->
        error
    end
  end

  defp receive_response(conn, ref, acc, timeout) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, events} ->
        case consume(events, ref, acc) do
          {:cont, acc} -> receive_response(conn, ref, acc, timeout)
          {:done, response} -> response
          {:error, error} -> normalize_error(error)
        end

      {:error, _conn, error, events} ->
        case consume(events, ref, acc) do
          {:done, response} -> response
          _ -> normalize_error(error)
        end
    end
  end

  defp consume([], _ref, acc), do: {:cont, acc}

  defp consume([{:status, ref, status} | rest], ref, {request, _response, _headers?}) do
    consume(rest, ref, {request, Req.Response.new(status: status, body: []), false})
  end

  defp consume([{:headers, ref, fields} | rest], ref, {request, response, headers?}) do
    key = if headers?, do: :trailers, else: :headers
    response = Map.put(response, key, Req.Response.new(headers: fields).headers)
    consume(rest, ref, {request, response, true})
  end

  defp consume([{:data, ref, data} | rest], ref, {request, response, headers?}) do
    case request.into do
      fun when is_function(fun, 2) ->
        case fun.({:data, data}, {request, response}) do
          {:cont, {request, response}} -> consume(rest, ref, {request, response, headers?})
          {:halt, {_request, response}} -> {:done, response}
        end

      nil ->
        consume(rest, ref, {request, %{response | body: [data | response.body]}, headers?})
    end
  end

  defp consume([{:done, ref} | _rest], ref, {request, response, _headers?}) do
    response =
      if is_nil(request.into),
        do: %{response | body: response.body |> Enum.reverse() |> IO.iodata_to_binary()},
        else: response

    {:done, response}
  end

  defp consume([{:error, ref, error} | _rest], ref, _acc), do: {:error, error}
  defp consume([_event | rest], ref, acc), do: consume(rest, ref, acc)

  defp within_deadline(deadline, flags) do
    if now() < deadline and :atomics.get(flags, 2) == 0,
      do: :ok,
      else: {:error, %Req.TransportError{reason: :timeout}}
  end

  defp tls_identity(transport, %URI{scheme: "https", host: host}) do
    transport
    |> Keyword.drop([:verify_fun, :customize_hostname_check])
    |> Keyword.put(:verify, :verify_peer)
    |> Keyword.put(:server_name_indication, String.to_charlist(host))
  end

  defp tls_identity(transport, _uri), do: transport

  defp authority(uri) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    if uri.port == URI.default_port(uri.scheme), do: host, else: "#{host}:#{uri.port}"
  end

  defp normalize_error(%Mint.TransportError{reason: reason}),
    do: %Req.TransportError{reason: reason}

  defp normalize_error(%Mint.HTTPError{module: module, reason: reason}) do
    protocol = if module == Mint.HTTP2, do: :http2, else: :http1
    %Req.HTTPError{protocol: protocol, reason: reason}
  end

  defp normalize_error(error), do: error
  defp now, do: System.monotonic_time(:millisecond)
end
