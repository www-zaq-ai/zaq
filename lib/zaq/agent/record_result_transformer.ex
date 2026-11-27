defmodule Zaq.Agent.RecordResultTransformer do
  @moduledoc """
  Projects signed Records into the minimum model-facing shape declared by
  `Zaq.Contracts.Record.zoi_type/1`.

  This happens after tool output validation and opaque aliasing. Keeping the
  projection shallow prevents the bounded transport sanitizer from replacing
  nested permission data with summaries. Provenance is the authority for signed
  claims; the visible fields give the model context.
  """

  alias ReqLLM.ToolResult
  alias Zaq.Contracts.Record

  @type result :: {:ok, term(), [term()]} | {:error, term(), [term()]}

  @doc "Projects signed Records without changing unsigned materialized output."
  @spec project_tool_result(map(), result(), map()) :: {:ok, result()}
  def project_tool_result(_tool_call, {:ok, %ToolResult{} = result, effects}, _context) do
    {:ok, {:ok, %{result | output: project(result.output)}, effects}}
  end

  def project_tool_result(_tool_call, {:ok, output, effects}, _context) do
    {:ok, {:ok, project(output), effects}}
  end

  def project_tool_result(_tool_call, result, _context), do: {:ok, result}

  defp project(%Record{provenance_ref: ref} = record) when is_binary(ref) do
    %{
      "id" => record.id,
      "kind" => to_string(record.kind),
      "name" => record.name,
      "content" => record.content,
      "parent_id" => record.parent_id,
      "path" => record.path,
      "mime_type" => record.mime_type,
      "size" => record.size,
      "materialization_handle" => record.materialization_handle,
      "permissions" => project_permissions(record.permissions),
      "attributes" => projected_attributes(record),
      "provenance_ref" => ref
    }
    |> put_visible("url", record.url)
    |> put_visible("parent_ids", record.parent_ids)
  end

  defp project(%Record{} = record), do: record
  defp project(%_{} = value), do: value |> Map.from_struct() |> project()
  defp project(values) when is_list(values), do: Enum.map(values, &project/1)
  defp project(%{} = values), do: Map.new(values, fn {key, value} -> {key, project(value)} end)
  defp project(value), do: value

  defp project_permissions(nil), do: nil
  defp project_permissions(permissions), do: Enum.map(permissions, &project_permission/1)

  defp project_permission(%Record{} = permission) do
    %{
      "id" => permission.id,
      "kind" => to_string(permission.kind),
      "name" => permission.name,
      "attributes" => permission.attributes || %{}
    }
  end

  defp project_permission(permission), do: permission

  defp projected_attributes(%Record{attributes: attrs} = record) do
    attrs = attrs || %{}

    %{"provider_record_id" => provider_record_id(record)}
    |> put_visible("encoding", Map.get(attrs, "encoding") || Map.get(attrs, :encoding))
    |> put_visible("provider", Map.get(attrs, "provider") || Map.get(attrs, :provider))
    |> put_visible("config_id", Map.get(attrs, "config_id") || Map.get(attrs, :config_id))
  end

  defp put_visible(map, _key, value) when value in [nil, []], do: map
  defp put_visible(map, key, value), do: Map.put(map, key, value)

  defp provider_record_id(%Record{attributes: attributes, id: id}) do
    Map.get(attributes || %{}, "provider_record_id") ||
      Map.get(attributes || %{}, :provider_record_id) || id
  end
end
