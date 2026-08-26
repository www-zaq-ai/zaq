defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  Data-source bridge over the storage volumes mounted on this install.

  Unlike a bridge fronting a remote provider, the files here are already inside ZAQ. That
  changes two things.

  Nothing is read on the channels node: every callback dispatches a `%Zaq.Event{}` to
  `:storage`, which owns mounted filesystem access. Storage answers with its own shapes —
  `Zaq.Storage.FileExplorer.Entry` values and flat permission grants — and mapping those
  onto `Zaq.Contracts.Record` is this module's job, the same way `Zaq.Channels.JidoConnectBridge`
  maps provider payloads. Storage never shapes a record: `materialize_document` answers with
  the bytes alone, and the caller merges them into the record this module already gave it.

  Records come back **unmaterialized**: `content: nil` plus a `materialization_handle`, so a
  listing does not drag file bytes across a node boundary for a caller that only wanted
  metadata. Redeeming that handle runs `Zaq.Storage.Materializers.DiskDocument`, which goes
  straight to storage rather than back through here — which is why `materialize_document`
  answers with the bytes alone rather than a record.

  A file is named by its source — volume plus relative path — which is the id `list_files/2`
  returns and `get_file/2`, `update_file/2`, and `delete_file/2` accept. It is deliberately
  not the `documents.id`: any file on a mounted volume is reachable whether or not it was
  ever ingested, so identity cannot depend on a document row existing.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.DataSourceBridge

  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Storage.FileExplorer.Entry
  alias Zaq.Storage.Materializers.DiskDocument
  alias Zaq.Storage.VolumeConfig
  alias Zaq.Utils

  @provider "disk"

  @resolved_capabilities %{
    list_items: true,
    count_items: true,
    list_principals: true,
    count_principals: true,
    get_item_metadata: true,
    download_items: true,
    create_item: true,
    update_item: true,
    delete_item: true,
    manage_item_permissions: true,
    search_items: true
  }

  @impl Zaq.Channels.Bridge
  def to_internal(_payload, _config), do: {:error, :unsupported}

  @impl Zaq.Channels.Bridge
  def capability_snapshot(_config) do
    resolved =
      DataSourceBridge.required_capabilities()
      |> Map.new(&{&1, Map.get(@resolved_capabilities, &1, false)})

    unsupported = for {capability, false} <- resolved, do: capability

    {:ok,
     %{
       required: DataSourceBridge.required_capabilities(),
       resolved: resolved,
       unsupported: unsupported,
       labels: DataSourceBridge.capability_meta()
     }}
  end

  @doc "Reports what the mounted volumes hold — file, folder, and principal counts."
  @impl true
  def channel_stats(config, params) when is_map(config) and is_map(params) do
    dispatch(:volume_stats, %{params: params}, config)
  end

  # -- files --

  @doc "Lists the documents on the mounted volumes as **unmaterialized** records — no content."
  @doc "Lists one generic source scope per configured disk volume."
  @impl true
  def list_source_scopes(config, _params) when is_map(config) do
    settings = config |> fetch("settings") |> VolumeConfig.normalize_settings()

    with :ok <- VolumeConfig.validate_settings(settings) do
      volumes =
        settings
        |> Map.fetch!("volumes")
        |> Enum.map(fn %{"name" => name} ->
          %{
            provider: @provider,
            config_id: config_id(config),
            scope_id: name,
            label: name,
            filters: %{"parent" => name}
          }
        end)

      {:ok, volumes}
    end
  end

  @impl true
  def list_files(config, params) when is_map(config) and is_map(params) do
    with {:ok, page} <- dispatch(:list_documents, %{params: params}, config) do
      {:ok, record_page(page, config)}
    end
  end

  @doc """
  Writes a file onto a storage volume.

  `path` is the destination directory and carries the volume; `name` is the file. Binary
  content travels base64-encoded under `encoding`. Storage owns which volumes are mounted,
  so it validates the destination rather than this bridge.
  """
  @impl true
  def create_file(config, params) when is_map(config) and is_map(params) do
    action = if folder_request?(params), do: :persist_directory, else: :persist_document

    with {:ok, %{entry: entry} = result} <- dispatch(action, persist_request(params), config) do
      {:ok, %{status: Map.get(result, :status, "created"), record: map_entry(entry, config)}}
    end
  end

  @doc "Returns one document as an unmaterialized record — metadata only, no content."
  @impl true
  def get_file(config, params) when is_map(config) and is_map(params) do
    file_id = to_string(fetch(params, "file_id"))

    with {:ok, %Entry{} = entry} <- dispatch(:describe_document, %{file_id: file_id}, config) do
      {:ok, %{record: map_entry(entry, config)}}
    end
  end

  @doc """
  Rewrites, renames, or moves an existing document.

  Every field but `file_id` is optional: `name` renames, `path` moves to another directory,
  `content` (with `encoding` for binary) overwrites the bytes.
  """
  @impl true
  def update_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, %{entry: entry} = result} <-
           dispatch(:update_document, update_request(params), config) do
      {:ok, %{status: Map.get(result, :status, "updated"), record: map_entry(entry, config)}}
    end
  end

  @doc """
  Removes the document row and the file behind it, along with its chunks and sidecars.

  Answers with the status alone. The file is gone by the time ingestion returns, so there is
  nothing left to describe — the same answer `JidoConnectBridge.delete_file/2` gives.
  """
  @impl true
  def delete_file(config, params) when is_map(config) and is_map(params) do
    dispatch(:delete_document, %{file_id: to_string(fetch(params, "file_id"))}, config)
  end

  @doc "Finds documents whose source or title matches `query`."
  @impl true
  def search_files(config, params) when is_map(config) and is_map(params) do
    with {:ok, page} <- dispatch(:search_documents, %{params: params}, config) do
      {:ok, record_page(page, config)}
    end
  end

  @doc """
  Returns the document as an **unmaterialized** record: `content: nil` plus the
  `materialization_handle` that fetches the bytes.

  Unlike a bridge fronting a system that holds the file, this one reads nothing. The bytes
  live on an ingestion volume, so carrying them back through here would route the whole
  payload across the channels node for no reason. A caller that actually wants the content
  redeems `record.materialization_handle`, which goes straight to storage. `Zaq.Materialization`
  redeems it as a nested handle and merges the bytes into the record this bridge already gave
  the caller.

  That makes this the same answer as `get_file/2` — the difference between the two is what
  the caller does with the record, not what this bridge reads.
  """
  @impl true
  def download_document(config, params) when is_map(config) and is_map(params) do
    get_file(config, params)
  end

  @doc "Lists who can read the given document — one record per person or team grant."
  @impl true
  def list_permissions(config, params) when is_map(config) and is_map(params) do
    file_id = to_string(fetch(params, "file_id"))

    with {:ok, grants} <- dispatch(:list_document_grants, %{file_id: file_id}, config) do
      {:ok, permission_page(grants, file_id)}
    end
  end

  # -- mapping --

  # Ingestion answers with volume entries; the canonical record shape is put on here. The
  # entry's `:directory` becomes the record's `:folder` — the two vocabularies meet at this
  # function and nowhere else.
  defp map_entry(%Entry{} = entry, config) do
    map_entry(entry, nil, config)
  end

  defp map_entry(%Entry{} = entry, permissions, config) do
    kind = kind(entry.type)

    %Record{
      id: entry.id,
      kind: kind,
      name: entry.name,
      parent_id: entry.parent_id,
      parent_ids: Enum.reject([entry.parent_id], &is_nil/1),
      path: entry.relative_path,
      mime_type: mime_type(kind, entry.name),
      materialization_handle: materialization_handle(kind, entry.id, config),
      permissions: permissions,
      size: entry.size,
      modified_at: entry.modified_at,
      attributes: %{
        "provider" => @provider,
        "config_id" => config_id(config),
        "provider_record_id" => entry.id,
        "volume" => entry.volume,
        "relative_path" => entry.relative_path,
        "source" => entry.source
      },
      raw: %{local_entry: entry}
    }
  end

  defp kind(:directory), do: :folder
  defp kind(_type), do: :file

  # A volume entry carries no declared type, so the extension is all there is to go on.
  defp mime_type(:file, name) when is_binary(name), do: MIME.from_path(name)
  defp mime_type(_kind, _name), do: nil

  # A record travels without its bytes — reading every file a listing names would be wasted
  # work. The handle is what fetches them when a caller actually wants the content, and it
  # redeems straight to ingestion rather than back through this bridge. A folder has nothing
  # to materialize, and an unsignable handle leaves the record metadata-only rather than
  # failing the whole listing.
  defp materialization_handle(:file, id, config) when is_binary(id) do
    case DiskDocument.issue(id, %{"config_id" => config_id(config)}) do
      {:ok, handle} -> handle
      {:error, _reason} -> nil
    end
  end

  defp materialization_handle(_kind, _id, _config), do: nil

  defp record_page(%{entries: entries, scanned: scanned} = page, config) do
    records = Enum.map(entries, &map_entry(&1, entry_permissions(&1, page), config))

    %RecordPage{
      resource_type: :item,
      records: records,
      pagination:
        Map.merge(
          %RecordPage{resource_type: :item, records: []}.pagination,
          Map.get(page, :pagination, %{})
        ),
      stats: %{scanned: scanned, returned: length(records)}
    }
  end

  # Kept shape-compatible with providers that can report public grants. Disk storage entries
  # are private by default, so Storage currently always returns `public?: false`.
  defp permission_page(%{permissions: grants, public?: public?}, file_id) do
    records = public_records(public?, file_id) ++ Enum.map(grants, &map_permission/1)

    %RecordPage{
      resource_type: :permission,
      records: records,
      stats: %{scanned: length(records), returned: length(records)}
    }
  end

  defp public_records(false, _file_id), do: []

  defp public_records(true, file_id) do
    [
      %Record{
        id: "public:#{file_id}",
        kind: :permission,
        name: "Public",
        lifecycle_state: :active,
        attributes: %{"type" => "public", "target_id" => nil, "access_rights" => ["read"]}
      }
    ]
  end

  defp map_permission(grant) when is_map(grant) do
    %Record{
      id: to_string(grant.id),
      kind: :permission,
      name: grant.name,
      lifecycle_state: :active,
      attributes: %{
        "type" => grant.type,
        "target_id" => grant.target_id,
        "access_rights" => grant.access_rights || []
      },
      raw: %{
        "type" => grant.type,
        "target_id" => grant.target_id,
        "id" => grant.target_id,
        "display_name" => grant.name,
        "access_rights" => grant.access_rights || []
      }
    }
  end

  defp entry_permissions(%Entry{id: id}, %{permissions_by_id: permissions_by_id})
       when is_map(permissions_by_id) do
    Map.get(permissions_by_id, id)
  end

  defp entry_permissions(_entry, _page), do: nil

  # -- requests --

  defp persist_request(params) do
    %{
      "name" => fetch(params, "name"),
      "path" => fetch(params, "path"),
      "content" => fetch(params, "content") || "",
      "encoding" => fetch(params, "encoding")
    }
  end

  defp folder_request?(params) when is_map(params) do
    fetch(params, "kind") in ["folder", :folder] or fetch(params, "type") in ["folder", :folder]
  end

  # Only the keys the caller actually sent travel, so ingestion can tell "leave this alone"
  # from "set this to empty" — an absent `content` must not truncate the file.
  defp update_request(params) do
    ["name", "path", "content", "encoding"]
    |> Enum.reduce(%{"file_id" => to_string(fetch(params, "file_id"))}, fn key, request ->
      case fetch(params, key) do
        nil -> request
        value -> Map.put(request, key, value)
      end
    end)
  end

  # -- dispatch --

  # Storage owns filesystem configuration, so only the Disk ChannelConfig identity crosses the
  # role boundary. The router is read off `config`, never off `params`: `params` is
  # caller-supplied data that reaches here verbatim from agent tools, and choosing the dispatch
  # target from it would make what runs a function of what the caller sent.
  defp dispatch(action, request, config) do
    node_router = fetch(config, "node_router") || NodeRouter
    config_id = config_id(config)
    {request, actor} = pop_internal_actor(request)

    event_opts =
      [action: action]
      |> maybe_put(:config, fetch(config, "config"))
      |> maybe_put(:config_id, config_id)

    request
    |> Event.new(:storage, opts: event_opts, actor: actor)
    |> node_router.dispatch()
    |> Map.fetch!(:response)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Params arrive from agent tools with string keys and from internal callers with atom keys;
  # accept either rather than forcing every caller to normalise first.
  defp pop_internal_actor(%{params: params} = request) when is_map(params) do
    {params, actor} = pop_internal_actor(params)
    {%{request | params: params}, actor}
  end

  defp pop_internal_actor(%{"params" => params} = request) when is_map(params) do
    {params, actor} = pop_internal_actor(params)
    {%{request | "params" => params}, actor}
  end

  defp pop_internal_actor(request) when is_map(request) do
    {actor, request} = Map.pop(request, :__event_actor)
    {request, actor}
  end

  defp fetch(params, key), do: Utils.Map.present_value(params, key)
end

  defp config_id(%{id: id}), do: id
  defp config_id(%{"id" => id}), do: id
  defp config_id(_config), do: nil
