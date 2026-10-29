defmodule Zaq.Materialization do
  @moduledoc """
  Issues and redeems JSON-safe materialization handles.
  """

  alias Zaq.Contracts.Record
  alias Zaq.MapUtils
  alias Zaq.Materialization.{Handle, Registry, Sink}

  @max_nested_materializations 3
  @default_max_bytes 50 * 1024 * 1024
  @default_max_file_bytes 2 * 1024 * 1024 * 1024
  @document_mime_options ["document_mime_type", "export_mime_type"]

  @spec issue(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate issue(type, locator, opts \\ []), to: Handle

  @doc "Returns the shared request-time MIME option names for document materializers."
  def document_mime_options, do: @document_mime_options

  @doc """
  Redeems a handle into a record that carries its full content in memory.

  This is the bounded bytes API for consumers that need the bytes themselves (model tool
  results, previews). Producers stream into a memory sink capped by
  `config :zaq, :materialization_max_bytes` (default 50 MiB), so acquisition stops at the cap
  instead of buffering an unbounded body. Consumers that only need a file should use
  `materialize_file/5`.

  Options: `:max_bytes` overrides the configured cap for one call.
  """
  @spec materialize(String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def materialize(
        handle,
        context \\ %{},
        error_prefix \\ "Materialization failed",
        options \\ %{}
      )
      when is_binary(handle) and is_map(context) and is_map(options) do
    max_bytes = Map.get(context, :materialization_max_bytes) || max_bytes()

    with_sink([mode: :memory, max_bytes: max_bytes], error_prefix, fn sink ->
      context = Map.put(context, :materialization_sink, sink)

      with {:ok, %{record: record} = payload} <-
             materialize_handle(handle, context, error_prefix, 0, options),
           :ok <- check_inline_content(record, max_bytes, error_prefix),
           {:ok, record} <- adopt_memory(record, sink, error_prefix) do
        {:ok, %{payload | record: record}}
      else
        {:error, reason} -> {:error, sink_failure(sink, reason, error_prefix)}
      end
    end)
  end

  @doc """
  Redeems a handle into a file on the calling node.

  The producer streams chunks into a consumer-owned `Zaq.Materialization.Sink` (also across
  nested handles and role/node hops), so the body is never held in memory. Returns the record
  without content plus `file: %{path, size, binary?, sink}`. Until the caller confirms with
  `complete_file/1` (once it has adopted the file) or gives it up with `discard_file/1`, the
  sink keeps monitoring the calling process and removes the file if that process exits, so a
  finished file is never without an owner. After `complete_file/1` the caller owns `path` and
  must remove it. `file` is `nil` when the producer cannot stream and returned
  `content` (rows, inline text/Base64) instead; that content stays in `record.content` for the
  caller's existing handling, after a post-hoc size check against the quota.

  Options:

    * `:dir` — directory for the partial file (required)
    * `:own_dir` — the directory was made for this call alone: cleanup before `complete_file/1`
      removes all of it, so a file renamed within it is covered too (default `false`)
    * `:max_bytes` — quota; default `config :zaq, :materialization_max_file_bytes` (2 GiB).
      A resource guard, not a substitute for streaming.
  """
  @spec materialize_file(String.t(), map(), String.t(), map(), keyword()) ::
          {:ok, %{record: Record.t(), file: map() | nil}} | {:error, String.t()}
  def materialize_file(
        handle,
        context \\ %{},
        error_prefix \\ "Materialization failed",
        options \\ %{},
        file_opts
      )
      when is_binary(handle) and is_map(context) and is_map(options) and is_list(file_opts) do
    max_bytes = Keyword.get(file_opts, :max_bytes) || max_file_bytes()

    with_sink(
      [
        mode: :file,
        max_bytes: max_bytes,
        dir: Keyword.get(file_opts, :dir),
        own_dir: Keyword.get(file_opts, :own_dir, false)
      ],
      error_prefix,
      fn sink ->
        context = Map.put(context, :materialization_sink, sink)

        with {:ok, %{record: record}} <-
               materialize_handle(handle, context, error_prefix, 0, options),
             {:ok, record, file} <- adopt_file(record, sink, error_prefix) do
          {:ok, %{record: record, file: file && Map.put(file, :sink, sink)}}
        else
          {:error, reason} -> {:error, sink_failure(sink, reason, error_prefix)}
        end
      end
    )
  end

  @doc """
  Confirms that the caller has adopted the file returned by `materialize_file/5`.

  Returns `{:error, :file_removed}` when the file was already cleaned up (the owner exited or
  the file was discarded); the path must then not be used.
  """
  @spec complete_file(map() | nil) :: :ok | {:error, :file_removed}
  def complete_file(%{sink: sink}) when is_pid(sink) do
    case Sink.release(sink) do
      :ok -> :ok
      {:error, _} -> {:error, :file_removed}
    end
  end

  def complete_file(_file), do: :ok

  @doc "Gives up a file returned by `materialize_file/5` and removes it. Idempotent."
  @spec discard_file(map() | nil) :: :ok
  def discard_file(%{sink: sink}) when is_pid(sink), do: Sink.discard(sink)
  def discard_file(_file), do: :ok

  @doc "Configured cap for the in-memory bytes API."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.get_env(:zaq, :materialization_max_bytes, @default_max_bytes)

  @doc "Configured default quota for file materialization."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes,
    do: Application.get_env(:zaq, :materialization_max_file_bytes, @default_max_file_bytes)

  # Opens the sink and discards it on any error or exit. Only a finished file the caller was
  # handed (`file.sink`) keeps its sink alive, until `complete_file/1` or `discard_file/1`.
  defp with_sink(sink_opts, error_prefix, fun) do
    case Sink.open(sink_opts) do
      {:ok, sink} ->
        try do
          fun.(sink)
        catch
          kind, reason ->
            Sink.discard(sink)
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          {:ok, %{file: %{sink: ^sink}}} = handed_over ->
            handed_over

          result ->
            Sink.discard(sink)
            result
        end

      {:error, _reason} ->
        {:error, "#{error_prefix}: invalid materialization quota"}
    end
  end

  # Quota failures surface identically however the producer wrapped them.
  defp sink_failure(sink, reason, error_prefix) do
    case Sink.stats(sink) do
      %{failure: {:materialization_limit, max}} ->
        "#{error_prefix}: materialization size limit exceeded (#{max} bytes)"

      _ ->
        if is_binary(reason), do: reason, else: "#{error_prefix}: #{format_reason(reason)}"
    end
  end

  # Producers that ignore the sink return their bytes inline; enforce the cap post hoc.
  defp check_inline_content(%Record{content: content, attributes: attrs}, max, prefix)
       when is_binary(content) do
    if inline_size(content, attrs) > max,
      do: {:error, "#{prefix}: materialization size limit exceeded (#{max} bytes)"},
      else: :ok
  end

  defp check_inline_content(_record, _max, _prefix), do: :ok

  defp inline_size(content, attrs) do
    if encoding_from_attrs(attrs) == "base64" do
      size = byte_size(content)

      padding =
        cond do
          rem(size, 4) != 0 -> 0
          String.ends_with?(content, "==") -> 2
          String.ends_with?(content, "=") -> 1
          true -> 0
        end

      div(size * 3, 4) - padding
    else
      byte_size(content)
    end
  end

  # Streamed bodies leave `content: nil` and the bytes in the sink.
  defp adopt_memory(%Record{content: nil} = record, sink, prefix) do
    case Sink.stats(sink) do
      %{started?: true} ->
        case Sink.finish(sink) do
          {:ok, %{binary: binary, text?: text?}} ->
            base64? = encoding_from_attrs(record.attributes) == "base64" or not text?
            {:ok, put_streamed_content(record, binary, base64?)}

          {:error, reason} ->
            {:error, "#{prefix}: #{format_reason(reason)}"}
        end

      _ ->
        {:ok, record}
    end
  end

  defp adopt_memory(record, _sink, _prefix), do: {:ok, record}

  defp put_streamed_content(record, binary, true) do
    %{record | content: Base.encode64(binary), attributes: put_attr(record, "encoding", "base64")}
  end

  defp put_streamed_content(record, binary, false) do
    %{record | content: binary, attributes: Map.delete(record.attributes || %{}, "encoding")}
  end

  defp adopt_file(%Record{content: nil} = record, sink, prefix) do
    case Sink.stats(sink) do
      %{started?: true} ->
        case Sink.finish(sink) do
          {:ok, %{path: path, size: size, text?: text?}} ->
            binary? = encoding_from_attrs(record.attributes) == "base64" or not text?
            attrs = Map.delete(record.attributes || %{}, "encoding")

            {:ok, %{record | attributes: attrs}, %{path: path, size: size, binary?: binary?}}

          {:error, reason} ->
            {:error, "#{prefix}: #{format_reason(reason)}"}
        end

      _ ->
        {:ok, record, nil}
    end
  end

  # Producers that cannot stream return their bytes inline: they stay in `record.content`
  # for the consumer's existing handling, after a post-hoc check against the quota.
  defp adopt_file(%Record{content: content} = record, sink, prefix) when is_binary(content) do
    max = Sink.quota(sink)

    case check_inline_content(record, max, prefix) do
      :ok -> {:ok, record, nil}
      {:error, _} = error -> error
    end
  end

  defp adopt_file(record, _sink, _prefix), do: {:ok, record, nil}

  defp put_attr(%Record{attributes: attrs}, key, value),
    do: Map.put(attrs || %{}, key, value)

  defp materialize_handle(_handle, _context, error_prefix, depth, _options)
       when depth >= @max_nested_materializations do
    {:error, "#{error_prefix}: materialization depth exceeded"}
  end

  defp materialize_handle(handle, context, error_prefix, depth, options) do
    handle_opts = Map.get(context, :materialization_handle_opts, [])

    with {:ok, %{type: type, locator: locator}} <- Handle.verify(handle, handle_opts),
         {:ok, handler} <- Registry.lookup(type) do
      case materialize_with_handler(handler, locator, context, options) do
        {:ok, payload} -> normalize_payload(payload, context, error_prefix, depth)
        {:error, reason} -> {:error, "#{error_prefix}: #{format_reason(reason)}"}
        other -> {:error, "#{error_prefix}: unexpected materialize response #{inspect(other)}"}
      end
    else
      {:error, reason} -> {:error, "#{error_prefix}: #{format_reason(reason)}"}
    end
  end

  @doc "Validates string-keyed materialization options before calling a registered handler."
  @spec materialize_with_handler(module(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def materialize_with_handler(handler, locator, context, options)
      when is_atom(handler) and is_map(locator) and is_map(context) and is_map(options) do
    with {:ok, options} <- validate_options(options, materialization_options(handler)) do
      handler.do_materialize(locator, context, options)
    end
  end

  def materialize_with_handler(_handler, _locator, _context, _options),
    do: {:error, :invalid_materialization_locator}

  defp materialization_options(handler) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :materialization_options, 0),
      do: handler.materialization_options(),
      else: []
  end

  defp validate_options(options, allowed_options) do
    allowed_options = Enum.map(allowed_options, &to_string/1)

    cond do
      Enum.any?(Map.keys(options), &(not is_binary(&1))) ->
        {:error, :invalid_materialization_options}

      Map.keys(options) -- allowed_options != [] ->
        {:error, :invalid_materialization_options}

      true ->
        {:ok, options}
    end
  end

  defp normalize_payload(%{record: %Record{} = record}, context, prefix, depth),
    do: normalize_record(record, context, prefix, depth)

  defp normalize_payload(%{record: %{} = record}, context, prefix, depth),
    do: normalize_record(record, context, prefix, depth)

  defp normalize_payload(%{"record" => %{} = record}, context, prefix, depth),
    do: normalize_record(record, context, prefix, depth)

  defp normalize_payload(%{content: content} = payload, _context, _prefix, _depth),
    do:
      {:ok,
       %{
         record: put_encoding(%Record{id: "materialized", kind: :file, content: content}, payload)
       }}

  defp normalize_payload(%{"content" => content} = payload, _context, _prefix, _depth),
    do:
      {:ok,
       %{
         record: put_encoding(%Record{id: "materialized", kind: :file, content: content}, payload)
       }}

  defp normalize_payload(other, _context, error_prefix, _depth),
    do: {:error, "#{error_prefix}: unexpected materialize response #{inspect(other)}"}

  defp normalize_record(
         %Record{content: nil, materialization_handle: handle} = record,
         context,
         prefix,
         depth
       )
       when is_binary(handle) do
    with {:ok, %{record: nested}} <- materialize_handle(handle, context, prefix, depth + 1, %{}) do
      {:ok, %{record: merge_record(record, nested)}}
    end
  end

  defp normalize_record(%Record{} = record, _context, _prefix, _depth),
    do: {:ok, %{record: clear_handle(record)}}

  defp normalize_record(%{} = map, context, prefix, depth) do
    with {:ok, record} <- Record.from_map(map) do
      normalize_record(record, context, prefix, depth)
    end
  end

  defp merge_record(%Record{} = original, %Record{} = materialized) do
    clear_handle(%{
      original
      | content: materialized.content,
        attributes: merge_encoding(original.attributes, materialized)
    })
  end

  defp clear_handle(%Record{} = record), do: %{record | materialization_handle: nil}

  defp put_encoding(%Record{} = record, payload) do
    case encoding(payload) do
      nil -> record
      value -> %{record | attributes: Map.put(record.attributes || %{}, "encoding", value)}
    end
  end

  defp merge_encoding(attrs, materialized) do
    case encoding(materialized) do
      nil -> attrs || %{}
      value -> Map.put(attrs || %{}, "encoding", value)
    end
  end

  defp encoding(%Record{attributes: attrs}), do: encoding_from_attrs(attrs)

  defp encoding(%{} = map) do
    MapUtils.fetch(map, :encoding) || encoding_from_attrs(MapUtils.fetch(map, :attributes))
  end

  defp encoding_from_attrs(attrs) when is_map(attrs),
    do: Map.get(attrs, "encoding") || Map.get(attrs, :encoding)

  defp encoding_from_attrs(_attrs), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
