defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  Data-source bridge over the ingestion volumes mounted on this install.

  Unlike a bridge fronting a remote provider, the files here are already inside ZAQ. That
  changes two things.

  Nothing is read on the channels node: every callback dispatches a `%Zaq.Event{}` to
  `:ingestion`, which owns `FileExplorer` and the `documents` table. Ingestion answers with
  its own shapes — `Zaq.Ingestion.FileExplorer.Entry` values and flat permission grants — and
  mapping those onto `Zaq.Contracts.Record` is this module's job, the same way
  `Zaq.Channels.JidoConnectBridge` maps provider payloads.

  Records come back **unmaterialized**: `content: nil` plus a `materializing_event`, so a
  listing does not drag file bytes across a node boundary for a caller that only wanted
  metadata. Dispatching that event goes straight to ingestion, deliberately not back through
  here — which is why `materialize_record` is the one ingestion action that still answers
  with a record rather than an entry.

  A file is named by its `documents.id`, the same handle `list_files/2` returns and
  `get_file/2`, `update_file/2`, and `delete_file/2` accept. Folders and files with no
  document row fall back to a volume-path id, since there is no document to name.
  """

  @behaviour Zaq.Channels.DataSourceBridge

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.Ingestion.FileExplorer.Entry
  alias Zaq.NodeRouter
  alias Zaq.Utils

  @provider "disk"

  @doc "Reports what the mounted volumes hold — file, folder, and principal counts."
  @impl true
  def channel_stats(config, params) when is_map(config) and is_map(params) do
    dispatch(:volume_stats, %{params: params}, config)
  end

  # -- files --

  @doc "Lists the documents on the mounted volumes as **unmaterialized** records — no content."
  @impl true
  def list_files(config, params) when is_map(config) and is_map(params) do
    with {:ok, page} <- dispatch(:list_records, %{params: params}, config) do
      {:ok, record_page(page)}
    end
  end

  @doc """
  Writes a file onto a volume and registers its document row.

  `path` is the destination directory and carries the volume; `name` is the file. Binary
  content travels base64-encoded under `encoding`, and `tags` are written onto the document
  row. Ingestion owns which volumes are mounted, so it validates the destination rather than
  this bridge.
  """
  @impl true
  def create_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, %{entry: entry} = result} <-
           dispatch(:persist_record, persist_request(params), config) do
      {:ok, %{status: Map.get(result, :status, "created"), record: map_entry(entry)}}
    end
  end

  @doc "Returns one document as an unmaterialized record — metadata only, no content."
  @impl true
  def get_file(config, params) when is_map(config) and is_map(params) do
    file_id = to_string(fetch(params, "file_id"))

    with {:ok, %Entry{} = entry} <- dispatch(:describe_record, %{file_id: file_id}, config) do
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
           dispatch(:update_record, update_request(params), config) do
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
    dispatch(:delete_record, %{file_id: to_string(fetch(params, "file_id"))}, config)
  end

  @doc "Finds documents whose source or title matches `query`."
  @impl true
  def search_files(config, params) when is_map(config) and is_map(params) do
    with {:ok, page} <- dispatch(:search_records, %{params: params}, config) do
      {:ok, record_page(page)}
    end
  end

  @doc """
  Returns the document as an **unmaterialized** record: `content: nil` plus the
  `materializing_event` that fetches the bytes.

  Unlike a bridge fronting a system that holds the file, this one reads nothing. The bytes
  live on an ingestion volume, so carrying them back through here would route the whole
  payload across the channels node for no reason. A caller that actually wants the content
  dispatches `record.materializing_event`, which goes straight to ingestion.

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

    with {:ok, grants} <- dispatch(:list_record_permissions, %{file_id: file_id}, config) do
      {:ok, permission_page(grants, file_id)}
    end
  end

  @doc """
  Grants a person, a team, or everyone access to a document or a folder.

  Answers with the same page `list_permissions/2` would, so a caller reads the result of its
  own write without a second call.

  A folder cascades: ingestion writes each grant onto every document under it, since a folder
  has no permissions of its own to hold one. That is ingestion's rule to apply, not this
  bridge's — the request travels whole and the fan-out happens where the documents live.
  """
  @impl true
  def update_permissions(config, params) when is_map(config) and is_map(params) do
    file_id = to_string(fetch(params, "file_id") || fetch(params, "path"))
    request = permissions_request(params)

    with {:ok, %{applied_to: applied_to} = grants} <-
           dispatch(:update_record_permissions, request, config) do
      page = permission_page(grants, file_id)
      {:ok, %RecordPage{page | stats: Map.put(page.stats, :applied_to, applied_to)}}
    end
  end

  # -- mapping --

  # Ingestion answers with volume entries; the canonical record shape is put on here. The
  # entry's `:directory` becomes the record's `:folder` — the two vocabularies meet at this
  # function and nowhere else.
  defp map_entry(%Entry{} = entry) do
    kind = kind(entry.type)

    %Record{
      id: entry.id,
      kind: kind,
      name: entry.name,
      path: entry.relative_path,
      mime_type: mime_type(kind, entry.name),
      materializing_event: materializing_event(kind, entry.id),
      size: entry.size,
      modified_at: entry.modified_at,
      attributes: %{
        "provider" => @provider,
        "volume" => entry.volume,
        "relative_path" => entry.relative_path,
        "source" => entry.source
      },
      raw: %{local_entry: entry}
    }
  end

  defp record_page(%{entries: entries, scanned: scanned}) do
    records = Enum.map(entries, &map_entry/1)

    %RecordPage{
      resource_type: :item,
      records: records,
      stats: %{scanned: scanned, returned: length(records)}
    }
  end

  # Public access has no `resource_permissions` row, so ingestion reports it as a flag and
  # the grant is synthesized here. Its id is derived from the document — stable across calls,
  # and visibly not a permission-row id.
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

  defp kind(:directory), do: :folder
  defp kind(_type), do: :file

  # A volume entry carries no declared type, so the extension is all there is to go on.
  defp mime_type(:file, name) when is_binary(name), do: MIME.from_path(name)
  defp mime_type(_kind, _name), do: nil

  # A record travels without its bytes — reading every file a listing names would be wasted
  # work. This is the hop that fetches them when a caller actually wants the content, and it
  # goes straight to ingestion rather than back through this bridge. A folder has nothing to
  # materialize.
  defp materializing_event(:file, id) when is_binary(id),
    do: Event.new(%{file_id: id}, :ingestion, opts: [action: :materialize_record])

  defp materializing_event(_kind, _id), do: nil

  # -- requests --

  defp persist_request(params) do
    %{
      "name" => fetch(params, "name"),
      "path" => fetch(params, "path"),
      "content" => fetch(params, "content") || "",
      "encoding" => fetch(params, "encoding"),
      "tags" => fetch(params, "tags") || []
    }
  end

  # Whichever handle the caller holds travels: `file_id` names a document or a folder, and
  # `path`/`volume` name one directly. Ingestion resolves it — this bridge does not have to
  # know which volume anything sits on.
  defp permissions_request(params) do
    ["file_id", "path", "volume", "grants"]
    |> Enum.reduce(%{}, fn key, request ->
      case fetch(params, key) do
        nil -> request
        value -> Map.put(request, key, value)
      end
    end)
    |> put_public(params)
  end

  # `public` is the one field where `false` carries an instruction — stop sharing this with
  # everyone — so it is read by key presence. `fetch/2` reports a `false` value as an absent
  # one, which would silently turn "unshare" into "leave as is".
  defp put_public(request, params) do
    case Utils.Map.read_any(params, ["public", :public]) do
      nil -> request
      public -> Map.put(request, "public", public)
    end
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

  # The bytes and the document rows live on the ingestion node, so every read crosses a role
  # boundary. The router is read off `config`, never off `params`: `params` is caller-supplied
  # data that reaches here verbatim from agent tools, and choosing the dispatch target from it
  # would make what runs a function of what the caller sent.
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
