defmodule Zaq.Ingestion.RecordSource do
  @moduledoc """
  Resolves canonical data-source records into content sources usable by ingestion.

  Ingestion receives records from Channels bridges and materializes them through
  signed handles. It does not resolve provider-specific paths or mounted volumes.
  """

  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Materialization

  alias Zaq.Ingestion.{ExternalSource, TemporaryMaterializationStore}

  @doc "Returns the normalized ingestion kind for a canonical record."
  @spec kind(Record.t()) :: atom()
  def kind(%Record{kind: kind}), do: normalize_kind(kind)

  @doc "Returns the path/source reference stored on an ingest job for a record."
  @spec job_path(Record.t()) :: String.t() | nil
  def job_path(%Record{} = record) do
    if ExternalSource.external?(record), do: ExternalSource.source(record)
  end

  @doc "Materializes a canonical record into the common ingestion worker input."
  @spec materialize(Record.t(), map()) :: {:ok, map()} | {:error, term()}
  def materialize(%Record{} = record, context \\ %{}) when is_map(context) do
    materialize_external(record, context)
  end

  @doc "Lists child records for a folder record."
  @spec list_children(Record.t(), map()) :: {:ok, [Record.t()]} | {:error, term()}
  def list_children(%Record{} = record, context \\ %{}) when is_map(context) do
    list_external_children(record, context)
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
      "attributes" => safe_attributes(record.attributes || %{}),
      "materialization_handle" => record.materialization_handle,
      "provenance_ref" => record.provenance_ref
    }
  end

  @doc "Deserializes a persisted source record map into a canonical record."
  @spec from_storage_map(map()) :: {:ok, Record.t()} | {:error, :invalid_source_record}
  def from_storage_map(%{} = map) do
    case Record.from_map(map) do
      {:ok, record} ->
        {:ok,
         %{
           record
           | kind: normalize_kind(record.kind),
             modified_at: decode_datetime(record.modified_at)
         }}

      {:error, _reason} ->
        {:error, :invalid_source_record}
    end
  end

  def from_storage_map(_), do: {:error, :invalid_source_record}

  defp materialize_external(%Record{} = record, context) do
    with {:ok, %{record: %Record{} = downloaded}} <- download_external(record, context),
         {:ok, stored} <- store_download(record, downloaded) do
      source = ExternalSource.source(record)

      {:ok,
       %{
         path: stored.absolute_path,
         record: record,
         cleanup_paths: stored[:cleanup_paths] || [],
         processor_opts: [
           source_override: source,
           document_title: record.name,
           document_metadata: ExternalSource.metadata(record)
         ]
       }}
    end
  end

  defp download_external(%Record{materialization_handle: handle}, context)
       when is_binary(handle) do
    Materialization.materialize(
      handle,
      data_source_context(context),
      "Data source document download failed"
    )
  end

  defp download_external(%Record{} = record, context) do
    attrs = %{
      "config_id" => ExternalSource.config_id(record),
      "document_mime_type" => record.mime_type
    }

    case DataSourceDocument.issue(
           ExternalSource.provider(record),
           ExternalSource.file_id(record),
           attrs
         ) do
      {:ok, handle} ->
        Materialization.materialize(
          handle,
          data_source_context(context),
          "Data source document download failed"
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_download(record, %Record{content: rows}) when is_list(rows) do
    record
    |> TemporaryMaterializationStore.write_markdown(rows_to_markdown(rows))
    |> with_cleanup_root()
  end

  defp store_download(record, %Record{content: content} = downloaded)
       when is_binary(content) do
    encoding = attr(downloaded, "encoding") || attr(downloaded, :encoding)

    if encoding == "base64" do
      with {:ok, binary} <- Base.decode64(content),
           {:ok, stored} <-
             TemporaryMaterializationStore.write_original(
               record,
               binary,
               extension_for(record, downloaded)
             ) do
        {:ok, Map.put(stored, :cleanup_paths, [stored.root_path])}
      end
    else
      record
      |> TemporaryMaterializationStore.write_markdown(content)
      |> with_cleanup_root()
    end
  end

  defp store_download(_record, _downloaded), do: {:error, :unsupported_downloaded_record}

  defp with_cleanup_root({:ok, %{root_path: root_path} = stored}),
    do: {:ok, Map.put(stored, :cleanup_paths, [root_path])}

  defp with_cleanup_root(error), do: error

  defp list_external_children(%Record{} = record, context) do
    params = %{
      "config_id" => ExternalSource.config_id(record),
      "filters" => %{"parent" => ExternalSource.file_id(record), "include_shared" => false},
      "include_permissions" => true
    }

    Event.new(%{provider: ExternalSource.provider(record), params: params}, :channels,
      actor: Map.get(context, :actor) || Map.get(context, "actor"),
      opts: data_source_opts(:data_source_list_files)
    )
    |> node_router(context).dispatch()
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

  defp extension_for(%Record{} = original, %Record{} = downloaded) do
    case extension_from_record(original) do
      ".bin" -> extension_from_record(downloaded)
      ext -> ext
    end
  end

  defp extension_from_record(%Record{name: name}) when is_binary(name) do
    case Path.extname(name) do
      "" -> ".bin"
      ext -> ext
    end
  end

  defp extension_from_record(%Record{mime_type: "application/pdf"}), do: ".pdf"
  defp extension_from_record(_), do: ".bin"

  defp attr(%Record{} = record, key), do: record |> attributes() |> Map.get(key)

  defp attributes(%Record{attributes: attrs}) when is_map(attrs), do: attrs
  defp attributes(%Record{}), do: %{}

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
      ~w(provider config_id provider_record_id source_url provider_url provider_mime_type volume relative_path source)

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

  defp safe_permissions(nil), do: nil

  defp safe_permissions(permissions) when is_list(permissions),
    do: Enum.map(permissions, &safe_permission/1)

  defp safe_permissions(_), do: []

  defp safe_permission(%Record{} = permission), do: Record.metadata(permission)

  defp safe_permission(permission) do
    permission
    |> stringify_map()
    |> Map.take(~w(id name email emailAddress email_address displayName display_name role type))
  end

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

  defp data_source_context(context) do
    %{}
    |> maybe_put_actor(Map.get(context, :actor) || Map.get(context, "actor"))
    |> Map.merge(%{
      data_source_bridge_module:
        Application.get_env(
          :zaq,
          :ingestion_data_source_bridge_module,
          Zaq.Channels.DataSourceBridge
        ),
      node_router: Map.get(context, :node_router) || Map.get(context, "node_router")
    })
  end

  defp maybe_put_actor(context, actor) when is_map(actor), do: Map.put(context, :actor, actor)
  defp maybe_put_actor(context, _actor), do: context

  defp node_router(%{} = context),
    do:
      Map.get(context, :node_router) ||
        Map.get(context, "node_router") ||
        Zaq.NodeRouter

  defp node_router(_context), do: Zaq.NodeRouter
end
