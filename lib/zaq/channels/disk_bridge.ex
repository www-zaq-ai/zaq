defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  Data-source bridge over the ingestion volumes mounted on this install.

  Unlike a bridge fronting a remote provider, the files here are already inside ZAQ. That
  changes two things.

  Nothing is read on the channels node: every callback dispatches a `%Zaq.Event{}` to
  `:ingestion`, which owns `FileExplorer` and the `documents` table. Ingestion answers with
  its own shapes — `Zaq.Ingestion.FileExplorer.Entry` values and flat permission grants — and
  mapping those onto `Zaq.Contracts.Record` is this module's job, the same way
  `Zaq.Channels.JidoConnectBridge` maps provider payloads. Ingestion never shapes a record:
  `materialize_record` answers with the bytes alone, and the caller merges them into the
  record this module already gave it.

  Records come back **unmaterialized**: `content: nil` plus a `materialization_handle`, so a
  listing does not drag file bytes across a node boundary for a caller that only wanted
  metadata. Redeeming that handle runs `Zaq.Ingestion.Materializers.DiskDocument`, which goes
  straight to ingestion rather than back through here — which is why `materialize_record`
  answers with the bytes alone rather than a record.

  A file is named by its source — volume plus relative path — which is the id `list_files/2`
  returns and `get_file/2`, `update_file/2`, and `delete_file/2` accept. It is deliberately
  not the `documents.id`: any file on a mounted volume is reachable whether or not it was
  ever ingested, so identity cannot depend on a document row existing.
  """

  @behaviour Zaq.Channels.DataSourceBridge

  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.Ingestion.FileExplorer.Entry
  alias Zaq.Ingestion.Materializers.DiskDocument
  alias Zaq.NodeRouter
  alias Zaq.Utils

  @provider "disk"

  # Which callback answers each data-source capability. A capability absent from this map has
  # no filesystem equivalent — versions, spreadsheets, and change webhooks.
  @capability_callbacks %{
    list_items: {:list_files, 2},
    count_items: {:channel_stats, 2},
    list_principals: {:list_permissions, 2},
    count_principals: {:channel_stats, 2},
    get_item_metadata: {:get_file, 2},
    download_items: {:download_document, 2},
    create_item: {:create_file, 2},
    update_item: {:update_file, 2},
    delete_item: {:delete_file, 2},
    search_items: {:search_files, 2}
  }

  @doc "Reports what the mounted volumes hold — file, folder, and principal counts."
  @impl true
  def channel_stats(config, params) when is_map(config) and is_map(params) do
    dispatch(:volume_stats, %{params: params}, config)
  end

  # -- files --

  @doc """
  Lists the documents on the mounted volumes as **unmaterialized** records — no content.

  Volume-root entries carry `bound`, which travels through to `attributes["bound"]`.
  """
  @impl true
  def list_files(config, params) when is_map(config) and is_map(params) do
    with {:ok, page} <- dispatch(:list_documents, %{params: params}, config) do
      {:ok, record_page(page)}
    end
  end

  @doc """
  Writes a file onto a volume and registers its document row.

  `path` is the destination directory and carries the volume; `name` is the file. Binary
  content travels base64-encoded under `encoding`. Ingestion owns which volumes are mounted,
  so it validates the destination rather than this bridge.
  """
  @impl true
  def create_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, %{entry: entry} = result} <-
           dispatch(:persist_document, persist_request(params), config) do
      {:ok, %{status: Map.get(result, :status, "created"), record: map_entry(entry)}}
    end
  end

  @doc "Returns one document as an unmaterialized record — metadata only, no content."
  @impl true
  def get_file(config, params) when is_map(config) and is_map(params) do
    file_id = to_string(fetch(params, "file_id"))

    with {:ok, %Entry{} = entry} <- dispatch(:describe_document, %{file_id: file_id}, config) do
      {:ok, %{record: map_entry(entry)}}
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
      {:ok, %{status: Map.get(result, :status, "updated"), record: map_entry(entry)}}
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
      {:ok, record_page(page)}
    end
  end

  @doc """
  Returns the document as an **unmaterialized** record: `content: nil` plus the
  `materialization_handle` that fetches the bytes.

  Unlike a bridge fronting a system that holds the file, this one reads nothing. The bytes
  live on an ingestion volume, so carrying them back through here would route the whole
  payload across the channels node for no reason. A caller that actually wants the content
  redeems `record.materialization_handle`, which goes straight to ingestion. `Zaq.Materialization`
  redeems it as a nested handle and merges the bytes into the record this bridge already gave
  the caller.

  That makes this the same answer as `get_file/2` — the difference between the two is what
  the caller does with the record, not what this bridge reads.
  """
  @impl true
  def download_document(config, params) when is_map(config) and is_map(params) do
    get_file(config, params)
  end

  @doc "Lists who can read the given document — one record per person, team, or public grant."
  @impl true
  def list_permissions(config, params) when is_map(config) and is_map(params) do
    file_id = to_string(fetch(params, "file_id"))

    with {:ok, grants} <- dispatch(:list_document_grants, %{file_id: file_id}, config) do
      {:ok, permission_page(grants, file_id)}
    end
  end

  @doc """
  Reports which data-source capabilities the mounted volumes can serve.

  A capability resolves to the callback that answers it, and only where this module actually
  exports that callback — so the BO never advertises something the dispatcher would refuse
  with `{:error, :unsupported}`. The gaps are gaps by nature, not omissions: a filesystem
  keeps no version history, holds no spreadsheets, and pushes no change webhooks.
  """
  @spec capability_snapshot(map()) :: {:ok, map()}
  def capability_snapshot(config) when is_map(config) do
    {resolved, unsupported} =
      Enum.reduce(DataSourceBridge.required_capabilities(), {%{}, []}, fn capability,
                                                                          {resolved, unsupported} ->
        case resolve_capability(capability) do
          {:ok, ref} -> {Map.put(resolved, capability, ref), unsupported}
          :error -> {resolved, [capability | unsupported]}
        end
      end)

    {:ok,
     %{
       required: DataSourceBridge.required_capabilities(),
       resolved: resolved,
       unsupported: Enum.reverse(unsupported),
       labels: DataSourceBridge.capability_meta()
     }}
  end

  defp resolve_capability(capability) do
    with {:ok, {fun, arity}} <- Map.fetch(@capability_callbacks, capability),
         true <- function_exported?(__MODULE__, fun, arity) do
      {:ok, "#{fun}/#{arity}"}
    else
      _ -> :error
    end
  end

  # -- mapping --

  # Puts the canonical record shape on an ingestion entry. The entry's `:directory` becomes
  # the record's `:folder` here and nowhere else.
  defp map_entry(%Entry{} = entry) do
    kind = kind(entry.type)

    %Record{
      id: entry.id,
      kind: kind,
      name: entry.name,
      path: entry.relative_path,
      mime_type: mime_type(kind, entry.name),
      materialization_handle: materialization_handle(kind, entry.id),
      size: entry.size,
      modified_at: entry.modified_at,
      attributes: attributes(entry),
      raw: %{local_entry: entry}
    }
  end

  # `bound` is absent rather than `nil` off a volume root, so reading it never asks whether a
  # file is there.
  defp attributes(%Entry{} = entry) do
    base = %{
      "provider" => @provider,
      "volume" => entry.volume,
      "relative_path" => entry.relative_path,
      "source" => entry.source
    }

    if is_boolean(entry.bound), do: Map.put(base, "bound", entry.bound), else: base
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
  defp materialization_handle(:file, id) when is_binary(id) do
    case DiskDocument.issue(id) do
      {:ok, handle} -> handle
      {:error, _reason} -> nil
    end
  end

  defp materialization_handle(_kind, _id), do: nil

  defp record_page(%{entries: entries, scanned: scanned}) do
    records = Enum.map(entries, &map_entry/1)

    %RecordPage{
      resource_type: :item,
      records: records,
      stats: %{scanned: scanned, returned: length(records)}
    }
  end

  # Public access has no `resource_permissions` row, so the grant is synthesized here. Its id
  # derives from the document — stable across calls, and visibly not a permission-row id.
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
      }
    }
  end

  # -- requests --

  defp persist_request(params) do
    %{
      "name" => fetch(params, "name"),
      "path" => fetch(params, "path"),
      "content" => fetch(params, "content") || "",
      "encoding" => fetch(params, "encoding")
    }
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

  # The router is read off `config`, never off `params` — `params` reaches here verbatim from
  # agent tools, so taking the dispatch target from it would let a caller choose what runs.
  defp dispatch(action, request, config) do
    node_router = fetch(config, "node_router") || NodeRouter

    request
    |> Event.new(:ingestion, opts: [action: action])
    |> node_router.dispatch()
    |> Map.fetch!(:response)
  end

  # Params arrive from agent tools with string keys and from internal callers with atom keys;
  # accept either rather than forcing every caller to normalise first.
  defp fetch(params, key), do: Utils.Map.present_value(params, key)
end
