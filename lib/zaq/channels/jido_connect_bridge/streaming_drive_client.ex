defmodule Zaq.Channels.JidoConnectBridge.StreamingDriveClient do
  @moduledoc """
  Google Drive content client that streams response bodies into a materialization sink.

  `jido_connect_google_drive` buffers the whole response before returning it and has no
  per-call size limit, but its action handler accepts a `google_drive_client` module in the
  credential lease. The bridge supplies this module for download and export calls only. It
  reuses the dependency's authenticated transport, query building and response
  normalization and differs in one way: each chunk of a 2xx body is written to the
  consumer-owned `Zaq.Materialization.Sink` as it arrives (synchronously, so the socket is
  read no faster than the sink accepts), and the request is halted as soon as the sink's
  quota would be exceeded. A declared `content-length` above the quota is rejected before
  any body byte is read; the running byte count is what is enforced.

  Behaviour kept from the buffered path:

    * default transient GET retries, except once body bytes were written to the sink
      (a restarted download must not append to a partial file);
    * non-2xx responses keep the provider error shape (body capped at 64 KiB and decoded);
    * JSON that `Req` would decode keeps its decoded meaning. The in-memory bytes API buffers
      it up to the call's own quota and lets the dependency normalize it as before. A file sink
      receives a top-level array as the Markdown table ingestion builds from decoded rows,
      one row at a time (`Zaq.Materialization.JsonArrayRows`), so the array is never held;
      any other JSON value is buffered up to `Zaq.Materialization.max_bytes/0` and handled by
      the dependency as before (objects are rejected). Other bodies are written raw;
    * responses are requested without transfer compression and any content-encoding is
      rejected, so the quota counts the bytes that become the file.

  The handler contract passes only `(params, access_token)`. Because the dependency invokes
  the client in the calling process, the sink is carried by `with_sink/2`, which scopes it to
  one call and restores the previous state on exit. Outside a scope the client fails closed.
  """

  alias Jido.Connect.Google.Drive.Client.{Params, Response, Transport}
  alias Zaq.Materialization
  alias Zaq.Materialization.{JsonArrayRows, Sink}

  @key {__MODULE__, :sink}
  @options_key {__MODULE__, :req_options}
  @error_body_cap 64 * 1024
  @transient_statuses [408, 429, 500, 502, 503, 504]

  @doc "Runs `fun` with `sink` as the target of Drive content downloads in this process."
  @spec with_sink(Sink.t(), (-> result)) :: result when result: term()
  def with_sink(sink, fun) when is_pid(sink) and is_function(fun, 0) do
    previous = Process.put(@key, sink)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc """
  Runs `fun` with extra `Req` options (for instance `base_url:`) for Drive content requests made
  by this client in this process.

  The scope is process-local and restored on exit, so a caller that needs another endpoint
  (a loopback server in a test, a regional proxy) does not have to change the dependency's
  application environment, which is shared by every process. The options are applied after the
  dependency's authenticated transport is built, so credentials stay under the dependency's
  control. Nothing in a request can set them: only code running in the process can.
  """
  @spec with_req_options(keyword(), (-> result)) :: result when result: term()
  def with_req_options(options, fun) when is_list(options) and is_function(fun, 0) do
    previous = Process.put(@options_key, options)

    try do
      fun.()
    after
      if previous, do: Process.put(@options_key, previous), else: Process.delete(@options_key)
    end
  end

  @spec download_file(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def download_file(%{file_id: file_id} = params, access_token) when is_binary(file_id) do
    fetch(
      "/v3/files/#{encode_id(file_id)}",
      Params.file_download_params(params),
      "*/*",
      params,
      access_token
    )
  end

  @spec export_file(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def export_file(%{file_id: file_id, mime_type: mime_type} = params, access_token)
      when is_binary(file_id) and is_binary(mime_type) do
    fetch(
      "/v3/files/#{encode_id(file_id)}/export",
      Params.file_export_params(params),
      mime_type,
      params,
      access_token
    )
  end

  defp fetch(url, query, accept, params, access_token) do
    case Process.get(@key) do
      sink when is_pid(sink) -> do_fetch(sink, url, query, accept, params, access_token)
      _ -> {:error, :materialization_sink_required}
    end
  end

  defp do_fetch(sink, url, query, accept, params, access_token) do
    access_token
    |> Transport.request()
    |> Req.merge(Process.get(@options_key, []))
    |> Req.get(
      url: url,
      params: query,
      headers: [{"accept", accept}],
      compressed: false,
      retry: &retry?(sink, &1, &2),
      into: collector(sink)
    )
    |> case do
      {:ok, %{private: %{zaq_failure: :invalid_json}}} -> invalid_content(params)
      {:ok, %{private: %{zaq_failure: failure}}} -> {:error, failure}
      {:ok, response} -> finish(sink, response, params)
      other -> Response.handle_file_content_response(other, params)
    end
  end

  # --- collection ---------------------------------------------------------------------------

  defp collector(sink) do
    fn {:data, data}, {request, response} ->
      response = Req.Response.put_private(response, :zaq_request, request)

      case route(sink, response, data) do
        {:cont, response} -> {:cont, {request, response}}
        {:halt, response} -> {:halt, {request, response}}
      end
    end
  end

  defp route(sink, response, data) do
    cond do
      response.status not in 200..299 ->
        collect_error_body(response, data)

      encoding = content_encoding(response) ->
        halt(response, {:unsupported_content_encoding, encoding})

      true ->
        case ensure_mode(sink, response, data) do
          {:undecided, response} -> blank(sink, response, data)
          {:buffer, response} -> buffer(sink, response, data)
          {:rows, response} -> rows(sink, response, data)
          {:stream, response} -> stream(sink, response, data)
        end
    end
  end

  defp collect_error_body(response, data) do
    size = Req.Response.get_private(response, :zaq_size, 0)

    if size + byte_size(data) > @error_body_cap do
      {:halt, response}
    else
      {:cont, append(response, data)}
    end
  end

  defp stream(sink, response, data) do
    with :ok <- start_once(sink, response),
         :ok <- Sink.write(sink, data) do
      {:cont, Req.Response.put_private(response, :zaq_streamed, true) |> count(data)}
    else
      {:error, failure} -> halt(response, failure)
    end
  end

  defp start_once(sink, response) do
    if Req.Response.get_private(response, :zaq_streamed, false),
      do: :ok,
      else: Sink.start(sink, declared_length(response))
  end

  # Blank bytes before the first JSON token are only counted, against the quota.
  defp blank(sink, response, data) do
    quota = Sink.quota(sink)

    if Req.Response.get_private(response, :zaq_size, 0) + byte_size(data) > quota do
      _ = Sink.fail(sink, {:materialization_limit, quota})
      halt(response, {:materialization_limit, quota})
    else
      {:cont, count(response, data)}
    end
  end

  # Bodies Req decodes into a value (JSON) that cannot be streamed as rows must be whole to be
  # decoded: bounded by `zaq_cap`.
  defp buffer(sink, response, data) do
    cap = Req.Response.get_private(response, :zaq_cap)
    size = Req.Response.get_private(response, :zaq_size, 0)

    if size + byte_size(data) > cap or (declared_length(response) || 0) > cap do
      _ = Sink.fail(sink, {:materialization_limit, cap})
      halt(response, {:materialization_limit, cap})
    else
      {:cont, append(response, data)}
    end
  end

  # A JSON array becomes the Markdown table ingestion builds from decoded rows, one row at a
  # time. The sink quota bounds the raw body as well as the rendered file.
  defp rows(sink, response, data) do
    quota = Req.Response.get_private(response, :zaq_cap)
    size = Req.Response.get_private(response, :zaq_size, 0)

    with true <- size + byte_size(data) <= quota or {:error, {:materialization_limit, quota}},
         :ok <- start_once(sink, response),
         state = Req.Response.get_private(response, :zaq_rows) || new_rows(sink, quota),
         {:ok, state} <- JsonArrayRows.feed(state, data) do
      {:cont,
       response
       |> Req.Response.put_private(:zaq_rows, state)
       |> Req.Response.put_private(:zaq_streamed, true)
       |> count(data)}
    else
      {:error, failure} ->
        _ = Sink.fail(sink, failure)
        halt(response, failure)
    end
  end

  defp new_rows(sink, quota) do
    element_limit = min(Materialization.max_bytes(), quota)
    JsonArrayRows.new(&Sink.write(sink, &1), element_limit)
  end

  defp halt(response, failure),
    do: {:halt, Req.Response.put_private(response, :zaq_failure, failure)}

  defp append(response, data) do
    chunks = Req.Response.get_private(response, :zaq_chunks, [])

    response
    |> Req.Response.put_private(:zaq_chunks, [data | chunks])
    |> count(data)
  end

  defp count(response, data) do
    size = Req.Response.get_private(response, :zaq_size, 0)
    Req.Response.put_private(response, :zaq_size, size + byte_size(data))
  end

  # Decided once, from the first non-blank byte. Bodies Req would not decode are streamed raw.
  # Bodies it would decode are JSON: the bytes API (memory sink) needs the decoded value, so it
  # buffers; a file sink streams an array as rows (what ingestion converts decoded rows to) and
  # buffers any other JSON value, which the dependency rejects or reads as a scalar.
  defp ensure_mode(sink, response, data) do
    case Req.Response.get_private(response, :zaq_mode) do
      nil -> decide_mode(sink, response, data)
      mode -> {mode, response}
    end
  end

  defp decide_mode(sink, response, data) do
    if decoded_by_req?(response) do
      decide_json_mode(sink, response, data)
    else
      {:stream, Req.Response.put_private(response, :zaq_mode, :stream)}
    end
  end

  defp decide_json_mode(sink, response, data) do
    quota = Sink.quota(sink)

    case Sink.stats(sink).mode do
      :file -> decide_file_json_mode(response, data, quota)
      _memory -> {:buffer, mode(response, :buffer, quota)}
    end
  end

  defp decide_file_json_mode(response, data, quota) do
    case first_significant(data) do
      :blank -> {:undecided, response}
      "[" -> {:rows, mode(response, :rows, quota)}
      _other -> {:buffer, mode(response, :buffer, min(Materialization.max_bytes(), quota))}
    end
  end

  defp mode(response, mode, cap) do
    response
    |> Req.Response.put_private(:zaq_mode, mode)
    |> Req.Response.put_private(:zaq_cap, cap)
  end

  # First byte that is not JSON whitespace (space, tab, CR, LF), or :blank if there is none.
  defp first_significant(<<ws, rest::binary>>) when ws in [?\s, ?\t, ?\r, ?\n],
    do: first_significant(rest)

  defp first_significant(<<byte, _rest::binary>>), do: <<byte>>
  defp first_significant(<<>>), do: :blank

  defp decoded_by_req?(response) do
    request = Req.Response.get_private(response, :zaq_request)
    probe = %{response | body: "[]"}

    match?({_request, %{body: body}} when is_list(body), Req.Steps.decode_body({request, probe}))
  end

  # --- completion ---------------------------------------------------------------------------

  defp finish(sink, response, params) do
    cond do
      response.status not in 200..299 or Map.get(response.private, :zaq_chunks, []) != [] ->
        response |> buffered_response() |> Response.handle_file_content_response(params)

      rows = Map.get(response.private, :zaq_rows) ->
        finish_rows(sink, response, params, rows)

      # Only blank bytes arrived where JSON was expected.
      blank_only?(response) ->
        invalid_content(params)

      true ->
        finish_streamed(sink, response, params, Map.get(response.private, :zaq_size, 0))
    end
  end

  defp blank_only?(%{private: private}),
    do: Map.get(private, :zaq_size, 0) > 0 and not Map.has_key?(private, :zaq_mode)

  # Streamed (or empty) body: the bytes are in the sink, not in the response.
  defp finish_streamed(sink, response, params, size) do
    with :ok <- start_once(sink, response),
         {:ok, normalized} <-
           Response.handle_file_content_response({:ok, %{response | body: ""}}, params) do
      {:ok, streamed_result(normalized, size)}
    end
  end

  # The rendered table is Markdown text however its cells look; `size` is the row count, as
  # for decoded rows.
  defp finish_rows(sink, response, params, rows) do
    with {:ok, rows} <- JsonArrayRows.finish(rows),
         :ok <- Sink.mark_text(sink),
         {:ok, normalized} <-
           Response.handle_file_content_response({:ok, %{response | body: ""}}, params) do
      {:ok, streamed_result(normalized, JsonArrayRows.rows(rows))}
    else
      {:error, :invalid_json} ->
        _ = Sink.fail(sink, :invalid_json)
        invalid_content(params)

      {:error, _} = error ->
        error
    end
  end

  defp streamed_result(normalized, size) do
    normalized
    |> Map.drop([:content, :content_base64, :encoding, :binary])
    |> Map.put(:size, size)
  end

  defp invalid_content(params) do
    Response.handle_file_content_response(
      {:ok, %{status: 200, body: :invalid, headers: %{}}},
      params
    )
  end

  defp buffered_response(response) do
    case decode(response) do
      %Req.Response{} = decoded -> {:ok, decoded}
      exception -> {:error, exception}
    end
  end

  # Applies the body decoding Req performs on a buffered response, so the dependency's
  # normalization sees what it saw before streaming.
  defp decode(%{private: private} = response) do
    body = private |> Map.get(:zaq_chunks, []) |> Enum.reverse() |> IO.iodata_to_binary()
    response = %{response | body: body}

    case private do
      %{zaq_request: request} ->
        case Req.Steps.decode_body({request, response}) do
          {_request, decoded} -> decoded
        end

      _ ->
        response
    end
  end

  # --- helpers ------------------------------------------------------------------------------

  # Req's `:safe_transient` policy, withheld once bytes reached the sink.
  defp retry?(sink, request, response_or_exception) do
    if Sink.stats(sink).size > 0, do: false, else: transient?(request, response_or_exception)
  end

  defp transient?(%{method: method}, %Req.Response{status: status})
       when method in [:get, :head],
       do: status in @transient_statuses

  defp transient?(%{method: method}, %Req.TransportError{reason: reason})
       when method in [:get, :head],
       do: reason in [:timeout, :econnrefused, :closed]

  defp transient?(%{method: method}, %Req.HTTPError{protocol: :http2, reason: :unprocessed})
       when method in [:get, :head],
       do: true

  defp transient?(_request, _response), do: false

  defp content_encoding(response) do
    encodings =
      response
      |> Req.Response.get_header("content-encoding")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 in ["", "identity"]))

    if encodings == [], do: nil, else: Enum.join(encodings, ", ")
  end

  defp declared_length(response) do
    with [value | _] <- Req.Response.get_header(response, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end

  defp encode_id(file_id), do: URI.encode(file_id, &URI.char_unreserved?/1)
end
