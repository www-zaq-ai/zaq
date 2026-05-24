defmodule ZaqWeb.Live.BO.System.SystemConfig.MCPRows do
  @moduledoc """
  Helpers for MCP endpoint form row state and payload parsing.
  """

  alias Zaq.Agent.MCP
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.ParseUtils

  def rows(%MCP.Endpoint{} = endpoint) do
    build_rows(endpoint)
  end

  def rows(endpoint) when is_map(endpoint) do
    build_rows(endpoint)
  end

  def rows(_), do: build_rows(%{})

  defp build_rows(endpoint) do
    %{
      args: list_to_rows(Map.get(endpoint, :args, [])),
      headers: map_to_rows(Map.get(endpoint, :headers, %{})),
      secret_headers: secret_map_to_rows(Map.get(endpoint, :secret_headers, %{})),
      environments: map_to_rows(Map.get(endpoint, :environments, %{})),
      secret_environments: secret_map_to_rows(Map.get(endpoint, :secret_environments, %{})),
      settings: Jason.encode!(Map.get(endpoint, :settings, %{}))
    }
  end

  def rows_from_params(params, fallback_rows) when is_map(params) do
    %{
      args:
        read_rows(
          Map.get(params, "args_rows"),
          Map.get(fallback_rows, :args, [blank_arg_row()])
        ),
      headers:
        read_rows(
          Map.get(params, "headers_rows"),
          Map.get(fallback_rows, :headers, [blank_kv_row()])
        ),
      secret_headers:
        read_rows(
          Map.get(params, "secret_headers_rows"),
          Map.get(fallback_rows, :secret_headers, [blank_kv_row()])
        ),
      environments:
        read_rows(
          Map.get(params, "environments_rows"),
          Map.get(fallback_rows, :environments, [blank_kv_row()])
        ),
      secret_environments:
        read_rows(
          Map.get(params, "secret_environments_rows"),
          Map.get(fallback_rows, :secret_environments, [blank_kv_row()])
        ),
      settings: Map.get(params, "settings_text", Map.get(fallback_rows, :settings, "{}"))
    }
  end

  def rows_from_params(_params, fallback_rows), do: normalize_rows_map(fallback_rows)

  def parse_endpoint_params(params, rows) when is_map(params) and is_map(rows) do
    type = Map.get(params, "type", "local")

    %{
      "name" => Map.get(params, "name", ""),
      "type" => type,
      "status" => Map.get(params, "status", "disabled"),
      "timeout_ms" => Map.get(params, "timeout_ms", "5000"),
      "command" => blank_to_nil(Map.get(params, "command", "")),
      "url" => blank_to_nil(Map.get(params, "url", "")),
      "predefined_id" => blank_to_nil(Map.get(params, "predefined_id", "")),
      "args" => parse_arg_rows(Map.get(rows, :args, [])),
      "headers" => parse_kv_rows(Map.get(rows, :headers, [])),
      "secret_headers" => parse_kv_rows(Map.get(rows, :secret_headers, [])),
      "environments" => parse_kv_rows(Map.get(rows, :environments, [])),
      "secret_environments" => parse_kv_rows(Map.get(rows, :secret_environments, [])),
      "settings" => parse_json_map(Map.get(rows, :settings, "{}"))
    }
    |> apply_mcp_type_scope(type)
  end

  def parse_endpoint_params(_params, _rows), do: %{}

  def build_endpoint_payload(params, rows_state) do
    rows = rows_from_params(params, rows_state)
    parsed = parse_endpoint_params(params, rows)
    {rows, parsed}
  end

  def add_row(rows_map, collection) when is_map(rows_map) do
    key = collection_to_key(collection)
    existing = Map.get(rows_map, key, [blank_kv_row()])
    blank = if key == :args, do: blank_arg_row(), else: blank_kv_row()
    Map.put(rows_map, key, existing ++ [blank])
  end

  def remove_row(rows_map, collection, index) when is_map(rows_map) do
    key = collection_to_key(collection)
    existing = Map.get(rows_map, key, [blank_kv_row()])

    next =
      existing
      |> Enum.with_index()
      |> Enum.reject(fn {_row, idx} -> idx == index end)
      |> Enum.map(&elem(&1, 0))

    fallback = if key == :args, do: [blank_arg_row()], else: [blank_kv_row()]
    Map.put(rows_map, key, if(next == [], do: fallback, else: next))
  end

  defp normalize_rows_map(rows_map) when is_map(rows_map) do
    %{
      args: normalize_rows(Map.get(rows_map, :args, [blank_arg_row()])),
      headers: normalize_rows(Map.get(rows_map, :headers, [blank_kv_row()])),
      secret_headers: normalize_rows(Map.get(rows_map, :secret_headers, [blank_kv_row()])),
      environments: normalize_rows(Map.get(rows_map, :environments, [blank_kv_row()])),
      secret_environments:
        normalize_rows(Map.get(rows_map, :secret_environments, [blank_kv_row()])),
      settings: Map.get(rows_map, :settings, "{}")
    }
  end

  defp normalize_rows_map(_), do: rows(%MCP.Endpoint{})

  defp parse_json_map(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        %{}

      text ->
        case Jason.decode(text) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end
    end
  end

  defp parse_json_map(_), do: %{}

  defp parse_arg_rows(rows) do
    rows
    |> Enum.map(fn row -> row["value"] || row[:value] || "" end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_kv_rows(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      key = row["key"] || row[:key] || ""
      value = row["value"] || row[:value] || ""
      key = String.trim(key)
      value = String.trim(value)

      if key == "" do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp read_rows(nil, fallback), do: normalize_rows(fallback)

  defp read_rows(rows_map, fallback) when is_map(rows_map) do
    rows =
      rows_map
      |> Enum.sort_by(fn {idx, _} -> ParseUtils.parse_int(idx, 0) end)
      |> Enum.map(fn {_idx, row} ->
        %{
          "key" => Map.get(row, "key", ""),
          "value" => Map.get(row, "value", "")
        }
      end)

    normalize_rows(if rows == [], do: fallback, else: rows)
  end

  defp read_rows(_other, fallback), do: normalize_rows(fallback)

  defp normalize_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(fn row ->
      %{
        "key" => row["key"] || row[:key] || "",
        "value" => row["value"] || row[:value] || ""
      }
    end)
    |> case do
      [] -> [%{"key" => "", "value" => ""}]
      list -> list
    end
  end

  defp normalize_rows(_), do: [%{"key" => "", "value" => ""}]

  defp list_to_rows(list) when is_list(list) do
    rows = Enum.map(list, &%{"key" => "", "value" => &1})
    if rows == [], do: [blank_arg_row()], else: rows
  end

  defp list_to_rows(_), do: [blank_arg_row()]

  defp map_to_rows(map) when is_map(map) do
    rows = Enum.map(map, fn {k, v} -> %{"key" => k, "value" => v} end)
    if rows == [], do: [blank_kv_row()], else: rows
  end

  defp map_to_rows(_), do: [blank_kv_row()]

  defp secret_map_to_rows(map) when is_map(map) do
    rows =
      Enum.map(map, fn {k, v} ->
        %{"key" => k, "value" => decrypt_secret_for_form(v)}
      end)

    if rows == [], do: [blank_kv_row()], else: rows
  end

  defp secret_map_to_rows(_), do: [blank_kv_row()]

  defp decrypt_secret_for_form(value) when is_binary(value) do
    case EncryptedString.decrypt(value) do
      {:ok, decrypted} -> decrypted
      _ -> ""
    end
  end

  defp decrypt_secret_for_form(_), do: ""

  defp blank_kv_row, do: %{"key" => "", "value" => ""}
  defp blank_arg_row, do: %{"key" => "", "value" => ""}

  defp collection_to_key("args"), do: :args
  defp collection_to_key("headers"), do: :headers
  defp collection_to_key("secret_headers"), do: :secret_headers
  defp collection_to_key("environments"), do: :environments
  defp collection_to_key("secret_environments"), do: :secret_environments
  defp collection_to_key(_), do: :headers

  defp apply_mcp_type_scope(attrs, "local") do
    attrs
    |> Map.put("url", nil)
    |> Map.put("headers", %{})
    |> Map.put("secret_headers", %{})
  end

  defp apply_mcp_type_scope(attrs, "remote") do
    attrs
    |> Map.put("command", nil)
    |> Map.put("args", [])
    |> Map.put("environments", %{})
    |> Map.put("secret_environments", %{})
  end

  defp apply_mcp_type_scope(attrs, _), do: attrs

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value
end
