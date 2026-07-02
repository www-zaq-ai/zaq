defmodule Zaq.Channels.JidoConnectBridge.FieldNormalization do
  @moduledoc """
  Provider/action/field normalization adapter for jido_connect bridge params.

  This layer keeps ZAQ-side normalization isolated from connector internals so
  it can be removed or narrowed when connectors provide equivalent behavior.
  """

  @spec normalize_all(atom() | String.t(), String.t() | nil, map()) :: map()
  def normalize_all(provider, action_id, fields_map) when is_map(fields_map) do
    Enum.reduce(fields_map, %{}, fn {field, value}, acc ->
      {normalized_field, normalized_value} =
        normalize_entry(provider, action_id, fields_map, field, value)

      if is_nil(normalized_field) do
        acc
      else
        Map.put(acc, normalized_field, normalized_value)
      end
    end)
  end

  defp normalize_entry(provider, action_id, fields_map, field, value)

  defp normalize_entry(provider, action_id, fields_map, field, value)
       when field in [:parent_id, "parent_id"] do
    cond do
      not google_drive_create_action?(provider, action_id) ->
        {field, value}

      map_has_parents?(fields_map) ->
        {nil, nil}

      parent_id = normalize_parent_id(value) ->
        {normalize_parents_key(field), [parent_id]}

      true ->
        {nil, nil}
    end
  end

  defp normalize_entry(provider, action_id, fields_map, field, value)
       when field in [:export_mime_type, "export_mime_type"] and is_binary(value) do
    if google_drive_export_file_action?(provider, action_id) and
         not map_has_mime_type?(fields_map) do
      {normalize_mime_key(field), value}
    else
      {field, value}
    end
  end

  defp normalize_entry(provider, action_id, _fields_map, field, value) do
    {field, normalize(provider, action_id, field, value)}
  end

  @spec normalize(atom() | String.t(), String.t() | nil, atom() | String.t(), any()) :: any()
  def normalize(provider, action_id, field, value)

  def normalize(provider, action_id, field, value)
      when field in [:query, "query", :q, "q"] and is_binary(value) do
    if google_drive_list_files_action?(provider, action_id) and plain_text_query?(value) do
      "name contains '#{escape_query_value(value)}'"
    else
      value
    end
  end

  def normalize(_provider, _action_id, _field, value), do: value

  defp google_drive_list_files_action?(provider, action_id) do
    provider_match? = to_string(provider) in ["google_drive", "google", "google.drive"]
    provider_match? and action_id == "google.drive.files.list"
  end

  defp google_drive_export_file_action?(provider, action_id) do
    provider_match? = to_string(provider) in ["google_drive", "google", "google.drive"]
    provider_match? and action_id == "google.drive.file.export"
  end

  defp google_drive_create_action?(provider, action_id) do
    provider_match? = to_string(provider) in ["google_drive", "google", "google.drive"]
    provider_match? and action_id in ["google.drive.file.create", "google.drive.folder.create"]
  end

  defp normalize_mime_key(field) when is_atom(field), do: :mime_type
  defp normalize_mime_key(_field), do: "mime_type"

  defp normalize_parents_key(field) when is_atom(field), do: :parents
  defp normalize_parents_key(_field), do: "parents"

  defp normalize_parent_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      parent_id -> parent_id
    end
  end

  defp normalize_parent_id(_value), do: nil

  defp map_has_mime_type?(fields_map) when is_map(fields_map) do
    Map.has_key?(fields_map, :mime_type) or Map.has_key?(fields_map, "mime_type")
  end

  defp map_has_parents?(fields_map) when is_map(fields_map) do
    Map.has_key?(fields_map, :parents) or Map.has_key?(fields_map, "parents")
  end

  defp plain_text_query?(query) when is_binary(query) do
    trimmed = String.trim(query)

    trimmed != "" and not drive_dsl_query?(trimmed)
  end

  defp drive_dsl_query?(query) when is_binary(query) do
    lowered = String.downcase(query)

    Enum.any?(
      [
        " contains ",
        " in parents",
        " and ",
        " or ",
        " not ",
        "mimeType",
        "trashed",
        "modifiedTime",
        "createdTime",
        "="
      ],
      &String.contains?(lowered, String.downcase(&1))
    )
  end

  defp escape_query_value(value) when is_binary(value), do: String.replace(value, "'", "\\'")
end
