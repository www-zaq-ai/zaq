defmodule Zaq.Materialization do
  @moduledoc """
  Issues and redeems JSON-safe materialization handles.
  """

  alias Zaq.Contracts.Record
  alias Zaq.MapUtils
  alias Zaq.Materialization.{Handle, Registry}

  @max_nested_materializations 3

  @spec issue(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate issue(type, locator, opts \\ []), to: Handle

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
      case handler.materialize(locator, context, options) do
        {:ok, payload} -> normalize_payload(payload, context, error_prefix, depth)
        {:error, reason} -> {:error, "#{error_prefix}: #{format_reason(reason)}"}
        other -> {:error, "#{error_prefix}: unexpected materialize response #{inspect(other)}"}
      end
    else
      {:error, reason} -> {:error, "#{error_prefix}: #{format_reason(reason)}"}
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
    map
    |> record_from_map()
    |> normalize_record(context, prefix, depth)
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

  defp record_from_map(map) do
    %Record{
      id: MapUtils.fetch(map, :id) || "materialized",
      kind: normalize_kind(MapUtils.fetch(map, :kind) || :file),
      content: MapUtils.fetch(map, :content),
      name: MapUtils.fetch(map, :name),
      parent_id: MapUtils.fetch(map, :parent_id),
      parent_ids: MapUtils.fetch(map, :parent_ids) || [],
      mime_type: MapUtils.fetch(map, :mime_type),
      path: MapUtils.fetch(map, :path),
      url: MapUtils.fetch(map, :url),
      size: MapUtils.fetch(map, :size),
      description: MapUtils.fetch(map, :description),
      icon: MapUtils.fetch(map, :icon),
      created_at: MapUtils.fetch(map, :created_at),
      modified_at: MapUtils.fetch(map, :modified_at),
      change_type: MapUtils.fetch(map, :change_type),
      lifecycle_state: MapUtils.fetch(map, :lifecycle_state),
      deleted_at: MapUtils.fetch(map, :deleted_at),
      permissions: MapUtils.fetch(map, :permissions),
      owners: MapUtils.fetch(map, :owners) || [],
      attributes: MapUtils.fetch(map, :attributes) || %{},
      materialization_handle: MapUtils.fetch(map, :materialization_handle)
    }
  end

  defp normalize_kind("file"), do: :file
  defp normalize_kind("folder"), do: :folder
  defp normalize_kind("permission"), do: :permission
  defp normalize_kind("spreadsheet"), do: :spreadsheet
  defp normalize_kind(kind) when is_binary(kind), do: :file
  defp normalize_kind(kind), do: kind

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
