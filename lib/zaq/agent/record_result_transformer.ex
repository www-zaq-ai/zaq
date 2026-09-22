defmodule Zaq.Agent.RecordResultTransformer do
  @moduledoc """
  Projects signed Records into the minimum model-facing shape declared by
  `Zaq.Contracts.Record.zoi_type/1`.

  This happens after tool output validation and opaque aliasing. Keeping the
  projection shallow prevents the bounded transport sanitizer from replacing
  nested permission data with summaries, while provenance still authenticates
  every projected field when a later tool accepts the Record.
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
      "attributes" => %{"provider_record_id" => provider_record_id(record)},
      "provenance_ref" => ref
    }
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

  defp provider_record_id(%Record{attributes: attributes, id: id}) do
    Map.get(attributes || %{}, "provider_record_id") ||
      Map.get(attributes || %{}, :provider_record_id) || id
  end
end
