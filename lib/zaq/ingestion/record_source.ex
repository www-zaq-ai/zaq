defmodule Zaq.Ingestion.RecordSource do
  @moduledoc """
  Resolves canonical records into content sources usable by ingestion.

  Phase 1 supports local volume records by resolving their `attributes` into
  volume-relative paths. Future external data-source phases should extend this
  boundary to fetch/export record content through NodeRouter-routed data-source
  events, without adding provider-specific ingestion logic.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event

  alias Zaq.Ingestion.{
    ExternalSidecarStore,
    ExternalSource,
    FileExplorer,
    VolumeRecords
  }

  alias Zaq.NodeRouter

  @doc "Returns the normalized ingestion kind for a canonical record."
  @spec kind(Record.t()) :: atom()
  def kind(%Record{kind: kind}), do: normalize_kind(kind)

  @doc "Returns the volume-relative path encoded in a canonical record."
  @spec relative_path(Record.t()) :: String.t() | nil
  def relative_path(%Record{} = record),
    do: attr(record, "relative_path") || attr(record, :relative_path) || record_path(record)

  @doc "Returns the local volume name encoded in a canonical record, when present."
  @spec volume(Record.t()) :: String.t() | nil
  def volume(%Record{} = record), do: attr(record, "volume") || attr(record, :volume)

  @doc "Returns the path/source reference stored on an ingest job for a record."
  @spec job_path(Record.t()) :: String.t() | nil
  def job_path(%Record{} = record) do
    if ExternalSource.external?(record),
      do: ExternalSource.source(record),
      else: relative_path(record)
  end

  @doc "Resolves a canonical record into a local filesystem path for processing."
  @spec resolve_path(Record.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_path(%Record{} = record) do
    case {volume(record), relative_path(record)} do
      {volume, path} when is_binary(volume) and is_binary(path) ->
        FileExplorer.resolve_path(volume, path)

      {nil, path} when is_binary(path) ->
        FileExplorer.resolve_path(path)

      _ ->
        {:error, :unsupported_record_source}
    end
  end

  @doc "Materializes a canonical record into the common ingestion worker input."
  @spec materialize(Record.t()) :: {:ok, map()} | {:error, term()}
  def materialize(%Record{} = record) do
    if ExternalSource.external?(record) do
      materialize_external(record)
    else
      with {:ok, path} <- resolve_path(record) do
        {:ok, %{path: path, record: record, processor_opts: [], cleanup_paths: []}}
      end
    end
  end

  @doc "Lists child records for a folder record."
  @spec list_children(Record.t()) :: {:ok, [Record.t()]} | {:error, term()}
  def list_children(%Record{} = record) do
    if ExternalSource.external?(record) do
      list_external_children(record)
    else
      volume = volume(record)

      with path when is_binary(path) <- relative_path(record),
           {:ok, entries} <- list_entries(volume, path) do
        {:ok, VolumeRecords.from_entries(entries, volume, path)}
      end
    end
  end

  @doc "Serializes a canonical record into a JSON-safe map for persistence."
  @spec to_storage_map(Record.t()) :: map()
  def to_storage_map(%Record{} = record) do
    %{
      "id" => record.id,
      "kind" => to_string(record.kind),
      "name" => record.name,
      "path" => record.path,
      "url" => record.url,
      "icon" => record.icon,
      "parent_id" => record.parent_id,
      "parent_ids" => record.parent_ids || [],
      "mime_type" => record.mime_type,
      "size" => record.size,
      "modified_at" => encode_datetime(record.modified_at),
      "owners" => safe_owners(record.owners),
      "permissions" => safe_permissions(record.permissions),
      "attributes" => safe_attributes(record.attributes || %{})
    }
  end

  @doc "Deserializes a persisted source record map into a canonical record."
  @spec from_storage_map(map()) :: {:ok, Record.t()} | {:error, :invalid_source_record}
  def from_storage_map(%{"id" => id, "kind" => kind} = map) do
    {:ok,
     %Record{
       id: id,
       kind: normalize_kind(kind),
       name: Map.get(map, "name"),
       path: Map.get(map, "path"),
       url: Map.get(map, "url"),
       icon: Map.get(map, "icon"),
       parent_id: Map.get(map, "parent_id"),
       parent_ids: Map.get(map, "parent_ids", []),
       mime_type: Map.get(map, "mime_type"),
       size: Map.get(map, "size"),
       modified_at: decode_datetime(Map.get(map, "modified_at")),
       owners: Map.get(map, "owners", []),
       permissions: storage_permissions(Map.get(map, "permissions", [])),
       attributes: Map.get(map, "attributes", %{})
     }}
  end

  def from_storage_map(_), do: {:error, :invalid_source_record}

  defp list_entries(nil, path), do: FileExplorer.list(path)
  defp list_entries(volume, path), do: FileExplorer.list(volume, path)

  defp materialize_external(%Record{} = record) do
    with {:ok, %{record: %Record{} = downloaded}} <- download_external(record),
         {:ok, stored} <- store_download(record, downloaded) do
      sidecar_source = ExternalSource.sidecar_source(record)
      source = ExternalSource.source(record)
      sidecar_relative_path = ExternalSource.sidecar_relative_path(record, ".md")

      {:ok,
       %{
         path: stored.absolute_path,
         record: record,
         cleanup_paths: stored[:cleanup_paths] || [],
         processor_opts: [
           source_override: source,
           sidecar_source_override: sidecar_source,
           document_title: record.name,
           document_metadata: ExternalSource.metadata(record),
           sidecar_metadata: ExternalSource.sidecar_metadata(record, sidecar_relative_path)
         ]
       }}
    end
  end

  defp download_external(%Record{} = record) do
    params = %{
      "config_id" => ExternalSource.config_id(record),
      "file_id" => ExternalSource.file_id(record),
      "document_mime_type" => record.mime_type
    }

    Event.new(%{provider: ExternalSource.provider(record), params: params}, :channels,
      opts: data_source_opts(:data_source_download_document)
    )
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp store_download(record, %Record{content: rows}) when is_list(rows) do
    record
    |> ExternalSidecarStore.write_markdown(rows_to_markdown(rows))
    |> with_cleanup([])
  end

  defp store_download(record, %Record{content: content} = downloaded)
       when is_binary(content) do
    encoding = attr(downloaded, "encoding") || attr(downloaded, :encoding)

    if encoding == "base64" do
      with {:ok, binary} <- Base.decode64(content),
           {:ok, stored} <-
             ExternalSidecarStore.write_original(record, binary, extension_for(downloaded)) do
        {:ok, Map.put(stored, :cleanup_paths, [stored.absolute_path])}
      end
    else
      record
      |> ExternalSidecarStore.write_markdown(content)
      |> with_cleanup([])
    end
  end

  defp store_download(_record, _downloaded), do: {:error, :unsupported_downloaded_record}

  defp with_cleanup({:ok, stored}, cleanup_paths),
    do: {:ok, Map.put(stored, :cleanup_paths, cleanup_paths)}

  defp with_cleanup(error, _cleanup_paths), do: error

  defp list_external_children(%Record{} = record) do
    params = %{
      "config_id" => ExternalSource.config_id(record),
      "filters" => %{"parent" => ExternalSource.file_id(record), "include_shared" => false},
      "include_permissions" => true
    }

    Event.new(%{provider: ExternalSource.provider(record), params: params}, :channels,
      opts: data_source_opts(:data_source_list_files)
    )
    |> NodeRouter.dispatch()
    |> Map.get(:response)
    |> case do
      {:ok, %Zaq.Contracts.RecordPage{records: records}} ->
        {:ok, Enum.map(records || [], &inherit_external_attrs(&1, record))}

      error ->
        error
    end
  end

  defp inherit_external_attrs(%Record{} = child, %Record{} = parent) do
    attrs =
      child
      |> attributes()
      |> Map.put_new("provider", ExternalSource.provider(parent))
      |> Map.put_new("config_id", ExternalSource.config_id(parent))
      |> Map.put_new("provider_record_id", child.id)

    %Record{child | attributes: attrs}
  end

  defp rows_to_markdown([]), do: ""

  defp rows_to_markdown([first | _] = rows) when is_map(first) do
    headers = first |> Map.keys() |> Enum.map(&to_string/1)
    divider = Enum.map(headers, fn _ -> "---" end)

    ([headers, divider] ++
       Enum.map(rows, fn row ->
         Enum.map(headers, fn header -> row |> row_value(header) |> markdown_value() end)
       end))
    |> Enum.map_join("\n", fn columns -> "| " <> Enum.join(columns, " | ") <> " |" end)
  end

  defp rows_to_markdown(rows), do: Enum.map_join(rows, "\n", &markdown_value/1)

  defp row_value(row, header) do
    Enum.find_value(row, "", fn {key, value} ->
      if to_string(key) == header, do: value, else: false
    end)
  end

  defp markdown_value(nil), do: ""
  defp markdown_value(value) when is_binary(value), do: value
  defp markdown_value(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp markdown_value(value) when is_list(value) or is_map(value) do
    value
    |> json_safe_value()
    |> Jason.encode!()
  end

  defp markdown_value(value), do: safe_to_string(value)

  defp json_safe_value(%_{} = value), do: value |> Map.from_struct() |> json_safe_value()

  defp json_safe_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), json_safe_value(value)} end)
  end

  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)

  defp json_safe_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp json_safe_value(value), do: safe_to_string(value)

  defp safe_to_string(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> ""
  end

  defp extension_for(%Record{name: name}) when is_binary(name) do
    case Path.extname(name) do
      "" -> ".bin"
      ext -> ext
    end
  end

  defp extension_for(%Record{mime_type: "application/pdf"}), do: ".pdf"
  defp extension_for(_), do: ".bin"

  defp attr(%Record{} = record, key), do: record |> attributes() |> Map.get(key)

  defp attributes(%Record{attributes: attrs}) when is_map(attrs), do: attrs
  defp attributes(%Record{}), do: %{}

  defp record_path(%Record{path: path}), do: path

  defp normalize_kind(:directory), do: :folder
  defp normalize_kind(:folder), do: :folder
  defp normalize_kind("directory"), do: :folder
  defp normalize_kind("folder"), do: :folder
  defp normalize_kind(:file), do: :file
  defp normalize_kind("file"), do: :file
  defp normalize_kind(kind), do: kind

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(nil), do: nil
  defp encode_datetime(value), do: value

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp decode_datetime(value), do: value

  defp safe_attributes(attrs) when is_map(attrs) do
    allowed =
      ~w(provider config_id provider_record_id source_url provider_url provider_mime_type volume relative_path source related_record)

    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(allowed)
  end

  defp safe_attributes(_), do: %{}

  defp safe_owners(owners) when is_list(owners) do
    Enum.map(owners, fn owner ->
      owner
      |> stringify_map()
      |> Map.take(~w(id email display_name name photo_url))
    end)
  end

  defp safe_owners(_), do: []

  defp safe_permissions(permissions) when is_list(permissions) do
    Enum.map(permissions, fn
      %Record{} = permission ->
        raw = stringify_map(permission.raw || %{})

        %{
          "id" => permission.id,
          "name" => permission.name,
          "email" => raw["emailAddress"] || raw["email_address"] || permission.name,
          "display_name" => raw["displayName"] || raw["display_name"] || permission.name,
          "role" => raw["role"],
          "type" => raw["type"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()

      permission ->
        permission
        |> stringify_map()
        |> Map.take(
          ~w(id name email emailAddress email_address displayName display_name role type)
        )
    end)
  end

  defp safe_permissions(_), do: []

  defp storage_permissions(permissions) when is_list(permissions) do
    Enum.map(permissions, fn permission ->
      %Record{
        id: Map.get(permission, "id") || Map.get(permission, "email") || "permission",
        kind: :permission,
        name:
          Map.get(permission, "display_name") || Map.get(permission, "name") ||
            Map.get(permission, "email"),
        raw: permission
      }
    end)
  end

  defp storage_permissions(_), do: []

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_map(_), do: %{}

  defp data_source_opts(action) do
    [
      action: action,
      data_source_bridge_module:
        Application.get_env(
          :zaq,
          :ingestion_data_source_bridge_module,
          Zaq.Channels.DataSourceBridge
        )
    ]
  end
end
