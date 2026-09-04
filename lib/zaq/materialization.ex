defmodule Zaq.Materialization do
  @moduledoc """
  Issues and redeems JSON-safe materialization handles.
  """

  alias Zaq.Contracts.Record
  alias Zaq.MapUtils
  alias Zaq.Materialization.{Handle, Registry}
  alias Zaq.Utils.Map, as: MixedMap

  @max_nested_materializations 3
  @document_mime_options ["document_mime_type", "export_mime_type"]

  @spec issue(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate issue(type, locator, opts \\ []), to: Handle

  @doc "Returns the shared request-time MIME option names for document materializers."
  def document_mime_options, do: @document_mime_options

  @spec materialize(String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def materialize(
        handle,
        context \\ %{},
        error_prefix \\ "Materialization failed",
        options \\ %{}
      )
      when is_binary(handle) and is_map(context) and is_map(options) do
    materialize_handle(handle, context, error_prefix, 0, options)
  end

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

  @doc "Validates and normalizes materialization options before calling a registered handler."
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
    if function_exported?(handler, :materialization_options, 0),
      do: handler.materialization_options(),
      else: []
  end

  defp validate_options(options, allowed_options) do
    allowed_options = Enum.map(allowed_options, &to_string/1)
    allowed_keys = allowed_options ++ Enum.map(allowed_options, &String.to_existing_atom/1)

    cond do
      Map.keys(options) -- allowed_keys != [] ->
        {:error, :invalid_materialization_options}

      Enum.any?(allowed_options, &duplicate_option?(options, &1)) ->
        {:error, :invalid_materialization_options}

      true ->
        {:ok, supplied_options(options, allowed_options)}
    end
  end

  defp supplied_options(options, allowed_options) do
    options
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in allowed_options))
    |> Map.new(fn key -> {key, MixedMap.metadata_value(options, key)} end)
  end

  defp duplicate_option?(options, key) do
    Map.has_key?(options, key) and Map.has_key?(options, String.to_existing_atom(key))
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
