defmodule Zaq.Ingestion do
  @moduledoc """
  Public API for coordinating ingestion: trigger inline or async ingestion,
  query job statuses, retry and cancel jobs.

  Ingestion also owns user-facing document watch state and provider delta
  handling. Channels/Engine provide metadata-only provider changes; this context
  decides which watched records should be re-ingested, which removed records
  should delete existing documents and sidecars, and how folder watch inheritance
  is reflected in the BO UI.
  """

  alias Zaq.Ingestion.{
    ConnectorRegistry,
    ContentSource,
    DeleteService,
    DirectorySnapshot,
    Document,
    FileExplorer,
    FolderSetting,
    IngestChunkJob,
    IngestJob,
    IngestWorker,
    JobLifecycle,
    RecordSource,
    RenameService,
    Sidecar,
    SourcePath,
    VolumeRecords
  }

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Permissions.DocumentPermission, as: Permission

  alias Zaq.Repo
  alias Zaq.Utils.Map, as: MapUtils

  import Ecto.Query

  require Logger

  @pubsub Zaq.PubSub
  @topic "ingestion:jobs"

  # --- Ingestion triggers ---

  def ingest_records(records, params \\ %{}) when is_list(records) and is_map(params) do
    mode = normalize_mode(Map.get(params, "mode") || Map.get(params, :mode) || :async)

    {jobs, errors} = Enum.reduce(records, {[], []}, &collect_ingest_result(&1, mode, &2))

    if errors == [] do
      {:ok, Enum.reverse(jobs)}
    else
      {:error, {:partial_failure, Enum.reverse(jobs), Enum.reverse(errors)}}
    end
  end

  @doc """
  Processes metadata-only provider changes for a data-source watch channel.

  Records and provider signals are filtered through the same direct/inherited
  watch-state rules used by BO. Watched changed records are scheduled for async
  ingestion. Removed records delete matching source documents, chunks, linked
  sidecars, and external sidecar files when the watch state permits deletion.
  """
  def process_data_source_changes(request) when is_map(request) do
    provider = read_stringish(request, [:provider, "provider"])
    config_id = read_stringish(request, [:config_id, "config_id"])

    changed_records =
      request
      |> changed_records_from_request()
      |> Enum.map(&put_data_source_attrs(&1, provider, config_id))

    {records, ignored_records} =
      Enum.split_with(changed_records, &watched_data_source_record?(&1, provider, config_id))

    log_ignored_data_source_changes(ignored_records, provider, config_id)

    removed_count = delete_removed_data_source_documents(request, provider, config_id)

    with {:ok, jobs} <- ingest_records(records, %{mode: :async}) do
      {:ok, %{jobs: jobs, removed: removed_count}}
    end
  end

  def process_data_source_changes(_request), do: {:error, :invalid_request}

  def ingest_record(record, mode \\ :async) do
    case RecordSource.kind(record) do
      :file ->
        ingest_file_record(record, mode)

      :folder ->
        with {:ok, children} <- RecordSource.list_children(record) do
          children
          |> ingest_records(%{mode: mode})
        end

      _ ->
        {:error, :unsupported_record_kind}
    end
  end

  def ingest_file(path, mode \\ :async, volume_name \\ nil) do
    with {:ok, record} <- VolumeRecords.from_path(volume_name, path) do
      ingest_record(record, mode)
    end
  end

  def ingest_folder(path, mode \\ :async, volume_name \\ nil) do
    with {:ok, record} <- VolumeRecords.from_path(volume_name, path) do
      ingest_record(record, mode)
    end
  end

  # --- Content filter autocomplete ---

  @doc """
  Returns up to 50 `%ContentSource{}` structs for the @ mention autocomplete.

  Connector-level entries (one per configured connector) are always included first.
  When `query` is given, only document sources matching the query string are returned.

  Called via `NodeRouter.dispatch/1` with `%Zaq.Event{}` targeting ingestion role.
  Never call this directly from BO — use the NodeRouter boundary.
  """
  def list_document_sources(query \\ nil) do
    connector_sources =
      ConnectorRegistry.list_connectors()
      |> then(fn connectors ->
        if is_binary(query) and query != "",
          do: Enum.filter(connectors, &String.contains?(&1.id, query)),
          else: connectors
      end)
      |> Enum.map(fn %{id: id, label: label} ->
        %ContentSource{connector: id, source_prefix: id, label: label, type: :connector}
      end)

    db_sources = list_db_sources(query)

    (connector_sources ++ db_sources)
    |> Enum.uniq_by(& &1.source_prefix)
    |> Enum.take(50)
  end

  defp list_db_sources(query) do
    case parse_query(query) do
      :all -> name_search_sources(nil)
      {:name, name} -> name_search_sources(name)
      {:browse, folder_label, child_query} -> browse_sources(folder_label, child_query)
    end
  end

  defp parse_query(nil), do: :all
  defp parse_query(""), do: :all

  defp parse_query(query) when is_binary(query) do
    case String.split(query, "/", parts: 2) do
      [folder, child] -> {:browse, folder, child}
      [name] -> {:name, name}
    end
  end

  # Name search — returns folders and files whose label matches the query.
  defp name_search_sources(name) do
    condition =
      if name,
        do:
          dynamic(
            [d],
            ilike(d.source, ^"%#{name}%") and
              fragment("(? ->> 'source_document_source') IS NULL", d.metadata)
          ),
        else: dynamic([d], fragment("(? ->> 'source_document_source') IS NULL", d.metadata))

    name_lower = name && String.downcase(name)

    from(d in Document,
      where: ^condition,
      select: d.source,
      order_by: [asc: d.source],
      limit: 200
    )
    |> Repo.all()
    |> Enum.flat_map(fn source ->
      if name,
        do: derive_folder_prefixes(source) ++ [source],
        else: derive_folder_prefixes(source)
    end)
    |> Enum.uniq()
    |> Enum.map(&ContentSource.from_source/1)
    |> Enum.reject(&is_nil/1)
    |> then(fn sources ->
      if name_lower,
        do: Enum.filter(sources, &String.contains?(String.downcase(&1.label), name_lower)),
        else: sources
    end)
    |> Enum.sort_by(&String.length(&1.source_prefix))
    |> Enum.uniq_by(&{&1.connector, &1.label})
  end

  # Path browse — returns direct children (files + immediate subfolders) of the
  # named folder.  Uses an exact prefix query so sibling folders never leak in.
  # When child_query is empty (bare "@folder/"), prepends the folder itself as a
  # :current_folder entry so the user can apply the whole folder as a filter.
  defp browse_sources(folder_label, child_query) do
    canonical_paths = find_canonical_paths(folder_label)

    children =
      canonical_paths
      |> Enum.flat_map(fn canonical_path ->
        prefix = canonical_path <> "/"

        from(d in Document,
          where:
            like(d.source, ^"#{prefix}%") and
              fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
          select: d.source,
          order_by: [asc: d.source],
          limit: 100
        )
        |> Repo.all()
        |> extract_direct_children(canonical_path)
        |> Enum.map(&ContentSource.from_source/1)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq_by(& &1.source_prefix)
      |> then(fn sources ->
        if child_query != "" do
          child_lower = String.downcase(child_query)
          Enum.filter(sources, &String.contains?(String.downcase(&1.label), child_lower))
        else
          sources
        end
      end)

    if child_query == "" do
      folder_self =
        canonical_paths
        |> Enum.map(&to_current_folder_source/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.label)

      folder_self ++ children
    else
      children
    end
  end

  defp to_current_folder_source(path) do
    case ContentSource.from_source(path) do
      nil -> nil
      cs -> %{cs | type: :current_folder}
    end
  end

  # Resolves folder_label to its canonical full path(s) in the documents table.
  # Keeps the shallowest path per connector so @zaq/ always browses the top-level
  # "zaq" folder, not a nested "zaq" that happens to exist deeper.
  defp find_canonical_paths(folder_label) do
    label_lower = String.downcase(folder_label)

    from(d in Document,
      where:
        (ilike(d.source, ^"#{folder_label}/%") or
           ilike(d.source, ^"%/#{folder_label}/%")) and
          fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
      select: d.source,
      limit: 100
    )
    |> Repo.all()
    |> Enum.flat_map(&derive_folder_prefixes/1)
    |> Enum.uniq()
    |> Enum.filter(fn prefix ->
      String.downcase(List.last(String.split(prefix, "/"))) == label_lower
    end)
    |> Enum.sort_by(&String.length/1)
    |> Enum.uniq_by(fn path -> List.first(String.split(path, "/")) end)
  end

  # From a list of full source paths, extract one entry per immediate child of
  # canonical_path — collapsing deeper files into their parent subfolder path.
  defp extract_direct_children(sources, canonical_path) do
    prefix_len = String.length(canonical_path) + 1

    sources
    |> Enum.map(fn source ->
      rest = String.slice(source, prefix_len, String.length(source))
      first_segment = rest |> String.split("/") |> List.first()
      canonical_path <> "/" <> first_segment
    end)
    |> Enum.uniq()
  end

  # Returns all intermediate path prefixes for a source, excluding the leaf segment.
  # "zaq/hr/policy.pdf" → ["zaq", "zaq/hr"]
  defp derive_folder_prefixes(source) do
    parts = String.split(source, "/", trim: true)

    0..(length(parts) - 2)//1
    |> Enum.map(fn i -> parts |> Enum.take(i + 1) |> Enum.join("/") end)
  end

  # --- Access control ---

  @doc """
  Returns true if the given person can access a file at `relative_path`.
  - Super admins bypass all checks.
  - Files with no Document record are accessible to all (backward compat).
  - Documents tagged `"public"` are accessible to all.
  - Documents with no permission rows and no public tag are private (admin-only).
  - Otherwise: person must have a direct permission or a team permission.
  """
  def can_access_file?(relative_path, current_user) do
    source = SourcePath.normalize_relative(relative_path)

    case Document.get_by_source(source) do
      nil ->
        true

      doc ->
        super_admin? = current_user.role.name == "super_admin"
        permissions = list_document_permissions(doc.id)
        person_id = Map.get(current_user, :person_id)
        team_ids = Map.get(current_user, :team_ids) || []

        super_admin? or "public" in doc.tags or
          Enum.any?(permissions, fn p ->
            (not is_nil(p.person_id) and p.person_id == person_id) or
              (not is_nil(p.team_id) and p.team_id in team_ids)
          end)
    end
  end

  # --- Upload tracking ---

  def list_volumes, do: FileExplorer.list_volumes()

  @doc """
  Returns `true` when at least one ingestion volume is explicitly configured.

  Callers must use this rather than inspecting `list_volumes/0`, which never returns an
  empty map — see `Zaq.Ingestion.FileExplorer.volumes_configured?/0`.
  """
  def volumes_configured?, do: FileExplorer.volumes_configured?()

  def list_entries(nil, path), do: FileExplorer.list(path)
  def list_entries(volume_name, path), do: FileExplorer.list(volume_name, path)

  def create_directory(volume_name, path), do: FileExplorer.create_directory(volume_name, path)

  def rename_entry(volume_name, old_path, new_path),
    do: RenameService.rename_entry(volume_name, old_path, new_path)

  def upload_file(volume_name, path, content),
    do: FileExplorer.upload_unique(volume_name, path, content)

  def save_file(volume_name, path, content),
    do: FileExplorer.upload(volume_name, path, content)

  def file_info(volume_name, path), do: FileExplorer.file_info(volume_name, path)

  @doc """
  Returns canonical records for the given document ids.

  Ids with no document row, or whose file is gone from its volume, are dropped rather than
  failing the page — one missing document does not hide the rest. Callers that need to know
  an id was missing compare the returned ids against the ones they asked for.
  """
  @spec describe_records([String.t() | integer()]) :: {:ok, RecordPage.t()}
  def describe_records(file_ids) when is_list(file_ids) do
    records =
      Enum.flat_map(file_ids, fn file_id ->
        case describe_record(file_id) do
          {:ok, record} -> [record]
          {:error, _reason} -> []
        end
      end)

    {:ok, record_page(records, length(file_ids))}
  end

  @doc """
  Returns a page of canonical records.

  With no `filters["parent"]`, answers every file the deployment holds across all mounted
  volumes. With one, answers that directory's entries — folders alongside files, so a caller
  can walk the tree the way `RecordSource.list_children/1` does for a folder record. A parent
  is a volume-prefixed source, the same form `Document.source` carries.

  Ingested files answer with their `documents.id`, so an id read off this page is the one
  `describe_records/1` accepts.
  """
  @spec list_records(map()) :: {:ok, RecordPage.t()} | {:error, term()}
  def list_records(params \\ %{}) when is_map(params) do
    case parent_source(params) do
      nil -> list_all_records()
      parent -> list_directory_records(split_parent(parent))
    end
  end

  # Document rows already span every volume, so listing them needs no walk across the mounts.
  defp list_all_records do
    documents = Document.list()
    {:ok, record_page(records_for(documents), length(documents))}
  end

  defp list_directory_records({volume_name, path}) do
    with {:ok, entries} <- list_entries(volume_name, path) do
      {:ok,
       entries |> VolumeRecords.from_entries(volume_name, path) |> record_page(length(entries))}
    end
  end

  defp record_page(records, scanned) do
    %RecordPage{
      resource_type: :item,
      records: records,
      stats: %{scanned: scanned, returned: length(records)}
    }
  end

  @doc """
  Writes a file onto a mounted volume and registers its document row.

  `path` is the destination directory and must name a volume — a bare relative path has no
  volume to write to and is refused rather than silently landing on the default one. The
  file is deduplicated the way a BO upload is, so a name already taken yields
  `notes (1).md`; the returned record carries the name that was actually written.

  Creating is not ingesting: the document row exists immediately, but chunking and
  embedding still happen through the normal ingest flow.
  """
  @spec persist_record(map()) :: {:ok, map()} | {:error, term()}
  def persist_record(request) when is_map(request) do
    with {:ok, {volume_name, dir}} <- destination(request),
         {:ok, name} <- required(request, "name", :name_required),
         {:ok, content} <- decode_content(request),
         dest = dir |> Path.join(name) |> SourcePath.normalize_relative(),
         {:ok, absolute_path} <- upload_file(volume_name, dest, content),
         {:ok, %Document{} = document} <- track_upload(volume_name, absolute_path),
         {:ok, record} <- describe_document(document) do
      {:ok, %{status: "created", record: record}}
    end
  end

  @doc """
  Reads a document's bytes and returns it as a materialized record.

  This is the far end of the `materializing_event` every file record carries: the record
  travels without content so a listing does not read every file it names, and a caller that
  wants the bytes dispatches the event to land here.

  A textual document comes back as text, so a caller reading markdown does not have to
  decode it first. Anything else is base64 with `attributes["encoding"]` saying so — the
  convention `RecordSource.store_download/2` already reads. Send `encoding: "base64"` in the
  request to force it, which is how a caller asks for the raw bytes of a text file.
  """
  @spec materialize_record(map()) :: {:ok, map()} | {:error, term()}
  def materialize_record(request) when is_map(request) do
    with {:ok, file_id} <- required(request, "file_id", :file_id_required) do
      case Document.get(file_id) do
        %Document{} = document -> materialize_document(document, request)
        nil -> {:error, :not_found}
      end
    end
  end

  defp materialize_document(%Document{} = document, request) do
    with {:ok, record} <- describe_document(document),
         {:ok, absolute_path} <- RecordSource.resolve_path(record),
         {:ok, binary} <- File.read(absolute_path) do
      {:ok, %{record: put_content(record, binary, request)}}
    end
  end

  defp put_content(%Record{} = record, binary, request) do
    if base64?(record, binary, request) do
      %{
        record
        | content: Base.encode64(binary),
          attributes: Map.put(record.attributes, "encoding", "base64")
      }
    else
      %{record | content: binary}
    end
  end

  # `String.valid?/1` is not redundant with the mime check: an extension says what a file is
  # meant to be, not what it holds. A `.md` carrying invalid UTF-8 would otherwise come back
  # as a broken string, so it falls to base64 instead.
  defp base64?(%Record{} = record, binary, request) do
    MapUtils.present_value(request, "encoding") == "base64" or
      not (textual_mime?(record.mime_type) and String.valid?(binary))
  end

  @textual_mime_types ~w(
    application/json application/xml application/javascript
    application/yaml application/x-yaml application/x-sh
  )

  defp textual_mime?(mime) when is_binary(mime),
    do: String.starts_with?(mime, "text/") or mime in @textual_mime_types

  defp textual_mime?(_mime), do: false

  @doc """
  Returns records for documents whose source or title matches `query`.

  Matching is a case-insensitive substring over the stored source and title — there is no
  index behind it, so the page is capped. Chunk and sidecar rows are excluded; they are not
  files a caller can act on.
  """
  @spec search_records(map()) :: {:ok, RecordPage.t()} | {:error, term()}
  def search_records(params) when is_map(params) do
    with {:ok, query} <- required(params, "query", :query_required) do
      documents = search_documents(query)
      {:ok, record_page(records_for(documents), length(documents))}
    end
  end

  # A document whose file is gone from its volume is dropped rather than failing the page —
  # one missing file does not hide the rest.
  defp records_for(documents) do
    Enum.flat_map(documents, fn document ->
      case describe_document(document) do
        {:ok, record} -> [record]
        {:error, _reason} -> []
      end
    end)
  end

  defp search_documents(query) do
    pattern = "%#{query}%"

    from(d in Document,
      where: fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
      where: ilike(d.source, ^pattern) or ilike(d.title, ^pattern),
      order_by: [asc: d.source],
      limit: 100
    )
    |> Repo.all()
  end

  @doc """
  Reports what the mounted volumes hold.

  `root_folders` are the mounted volume names — a volume is the root a caller browses from.
  `folders_count` is derived from document sources rather than walked on disk, so it counts
  directories that hold at least one document.
  """
  @spec volume_stats() :: {:ok, map()}
  def volume_stats do
    sources =
      from(d in Document,
        where: fragment("(? ->> 'source_document_source') IS NULL", d.metadata),
        select: d.source
      )
      |> Repo.all()

    folders =
      sources
      |> Enum.map(&Path.dirname/1)
      |> Enum.reject(&(&1 in [".", "", "/"]))
      |> Enum.uniq()

    {:ok,
     %{
       files_count: length(sources),
       folders_count: length(folders),
       principals_count: count_principals(),
       root_folders: FileExplorer.list_volumes() |> Map.keys() |> Enum.sort()
     }}
  end

  # A principal is whoever a grant names, counted once no matter how many documents it
  # covers. Public access names nobody, so it is not a principal.
  defp count_principals do
    from(p in Permission,
      where: p.resource_type == "document",
      distinct: true,
      select: {p.person_id, p.team_id}
    )
    |> Repo.all()
    |> Enum.reject(&(&1 == {nil, nil}))
    |> length()
  end

  @doc """
  Returns who can read a document, one record per grant.

  A grant names a person, a team, or everyone. Person and team grants are rows in
  `resource_permissions`; public access is the `"public"` tag on the document itself, and is
  reported here as a grant too — a caller asking who can read a file should not have to know
  ZAQ stores the two differently. `attributes["type"]` says which kind it is, and
  `attributes["access_rights"]` what was granted.
  """
  @spec list_record_permissions(String.t() | integer()) ::
          {:ok, RecordPage.t()} | {:error, term()}
  def list_record_permissions(file_id) do
    case Document.get(file_id) do
      %Document{} = document ->
        records =
          public_records(document) ++
            Enum.map(list_document_permissions(document.id), &permission_record/1)

        {:ok,
         %RecordPage{
           resource_type: :permission,
           records: records,
           stats: %{scanned: length(records), returned: length(records)}
         }}

      nil ->
        {:error, :not_found}
    end
  end

  # Public access has no permission row to name, so the id is derived from the document —
  # stable across calls, and visibly not a `resource_permissions` id.
  defp public_records(%Document{} = document) do
    if "public" in (document.tags || []) do
      [
        %Record{
          id: "public:#{document.id}",
          kind: :permission,
          name: "Public",
          lifecycle_state: :active,
          attributes: %{"type" => "public", "target_id" => nil, "access_rights" => ["read"]}
        }
      ]
    else
      []
    end
  end

  defp permission_record(%Permission{} = permission) do
    {type, target_id, name} = permission_target(permission)

    %Record{
      id: to_string(permission.id),
      kind: :permission,
      name: name,
      lifecycle_state: :active,
      attributes: %{
        "type" => type,
        "target_id" => target_id,
        "access_rights" => permission.access_rights || []
      }
    }
  end

  defp permission_target(%Permission{person: %{} = person}),
    do: {"person", to_string(person.id), person.full_name || person.email}

  defp permission_target(%Permission{team: %{} = team}),
    do: {"team", to_string(team.id), team.name}

  defp permission_target(%Permission{}), do: {"unknown", nil, nil}

  @doc """
  Updates a file in place: rewrites its content, renames it, or moves it within its volume.

  Every field is optional and applied to whatever the document already is — `name` renames,
  `path` moves to another directory, `content` overwrites the bytes. Moves go through the
  same `rename_entry/3` a BO rename runs, so the document source and any linked sidecar move
  with the file in one transaction and the id stays stable.
  """
  @spec update_record(map()) :: {:ok, map()} | {:error, term()}
  def update_record(request) when is_map(request) do
    with {:ok, file_id} <- required(request, "file_id", :file_id_required) do
      case Document.get(file_id) do
        %Document{} = document -> update_document(document, request)
        nil -> {:error, :not_found}
      end
    end
  end

  defp update_document(%Document{} = document, request) do
    {volume_name, path} = SourcePath.split_source(document.source, nil)

    # Content is written at the current location before any move, so a request that both
    # rewrites and renames lands the new bytes under the new name.
    with :ok <- write_content(volume_name, path, request),
         {:ok, target} <- move_target(volume_name, path, request),
         :ok <- move(volume_name, path, target),
         %Document{} = updated <- Document.get(document.id),
         {:ok, record} <- describe_document(updated) do
      {:ok, %{status: "updated", record: record}}
    end
  end

  defp write_content(volume_name, path, request) do
    case MapUtils.present_value(request, "content") do
      nil ->
        :ok

      _content ->
        with {:ok, content} <- decode_content(request),
             {:ok, _absolute_path} <- save_file(volume_name, path, content) do
          :ok
        end
    end
  end

  defp move_target(volume_name, path, request) do
    name = MapUtils.present_value(request, "name") || Path.basename(path)

    case MapUtils.present_value(request, "path") do
      nil ->
        {:ok, path |> Path.dirname() |> Path.join(name) |> SourcePath.normalize_relative()}

      new_path ->
        case split_parent(new_path) do
          # A move names its volume the way a create does. Crossing volumes is refused rather
          # than half-done: `rename_entry/3` renames within one volume, so a cross-volume move
          # would leave the file moved and the sidecar behind.
          {^volume_name, dir} ->
            {:ok, dir |> Path.join(name) |> SourcePath.normalize_relative()}

          {nil, _dir} ->
            {:error, :volume_required}

          {_other_volume, _dir} ->
            {:error, :cross_volume_move_unsupported}
        end
    end
  end

  defp move(_volume_name, path, path), do: :ok
  defp move(volume_name, path, target), do: rename_entry(volume_name, path, target)

  @doc """
  Removes a document row and the file behind it.

  Delegates to the same `delete_path/4` a BO delete runs, so chunks and linked sidecars go
  with it. The record is captured before the delete so the caller learns what was removed.
  """
  @spec delete_record(String.t() | integer()) :: {:ok, map()} | {:error, term()}
  def delete_record(file_id) do
    case Document.get(file_id) do
      %Document{} = document -> delete_document(document)
      nil -> {:error, :not_found}
    end
  end

  defp delete_document(%Document{} = document) do
    record =
      case describe_document(document) do
        {:ok, record} -> record
        {:error, _reason} -> nil
      end

    {volume_name, path} = SourcePath.split_source(document.source, nil)

    case delete_path(volume_name, path, "file") do
      :ok -> {:ok, %{status: "deleted", record: record}}
      error -> error
    end
  end

  defp destination(request) do
    with {:ok, path} <- required(request, "path", :path_required) do
      case split_parent(path) do
        {nil, _dir} -> {:error, :volume_required}
        {volume_name, dir} -> {:ok, {volume_name, dir}}
      end
    end
  end

  # Binary uploads arrive base64-encoded because the request travels as JSON from agent
  # tools; anything else is written through as the text it already is.
  defp decode_content(request) do
    content = MapUtils.present_value(request, "content") || ""

    case MapUtils.present_value(request, "encoding") do
      "base64" ->
        case Base.decode64(content) do
          {:ok, binary} -> {:ok, binary}
          :error -> {:error, :invalid_base64}
        end

      _ ->
        {:ok, content}
    end
  end

  defp required(request, key, error) do
    case MapUtils.present_value(request, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  # `split_source/2` splits a file source, so it needs a "volume/rest" shape and leaves a bare
  # volume name untouched — which would then resolve against the default volume and answer
  # `:not_a_directory`. A parent naming a whole volume is that volume's root.
  defp split_parent(parent) do
    volumes = FileExplorer.list_volumes()

    if Map.has_key?(volumes, parent) do
      {parent, "."}
    else
      SourcePath.split_source(parent, nil, volumes)
    end
  end

  defp parent_source(params) do
    filters = MapUtils.present_value(params, "filters") || %{}

    case MapUtils.present_value(filters, "parent") do
      parent when is_binary(parent) and parent != "" -> parent
      _ -> nil
    end
  end

  defp describe_record(file_id) do
    case Document.get(file_id) do
      %Document{} = document -> describe_document(document)
      nil -> {:error, :not_found}
    end
  end

  defp describe_document(%Document{} = document) do
    {volume_name, path} = SourcePath.split_source(document.source, nil)

    with {:ok, %Record{} = record} <- VolumeRecords.from_path(volume_name, path) do
      # The document id is the identity the caller holds, so the record answers with it
      # rather than the volume-entry id `from_path/2` derives for browsing.
      {:ok, %{record | id: to_string(document.id)}}
    end
  end

  def directory_snapshot(volume_name, current_dir, current_user) do
    with {:ok, entries} <- list_entries(volume_name, current_dir) do
      sorted =
        entries
        |> Enum.sort_by(fn e -> {if(e.type == :directory, do: 0, else: 1), e.name} end)
        |> VolumeRecords.from_entries(volume_name, current_dir)

      {:ok, DirectorySnapshot.build(sorted, volume_name, current_dir, current_user)}
    end
  end

  def source_for(volume_name, path) do
    normalized = SourcePath.normalize_relative(path)
    candidates = SourcePath.source_candidates(volume_name, normalized)

    case Enum.find_value(candidates, &Document.get_by_source/1) do
      %Document{} = doc -> doc.source
      nil -> normalized
    end
  end

  @doc "Builds a stable source for a new local entry that may not have a document yet."
  def source_for_new_entry(volume_name, path) do
    path = SourcePath.normalize_relative(path)
    SourcePath.build_source(volume_name, path)
  end

  @doc "Marks local or provider document targets as pending watch requests."
  def request_watch(targets) when is_list(targets), do: set_watch_status(targets, "pending")

  @doc "Clears local or provider document watch state."
  def clear_watch(targets) when is_list(targets), do: set_watch_status(targets, "unwatched")

  @doc "Counts directly watched provider documents for a data-source config."
  def count_watched_provider_documents(provider, config_id)
      when is_binary(provider) and not is_nil(config_id) do
    prefix = Enum.join(["data_source", provider, to_string(config_id)], "/") <> "/%"

    from(d in Document,
      where: d.watch_status in ["pending", "watched"],
      where: like(d.source, ^prefix)
    )
    |> Repo.aggregate(:count)
  end

  def count_watched_provider_documents(_provider, _config_id), do: 0

  @doc "Returns active inherited watch state for a provider record id, if any."
  def data_source_inherited_watch(provider, config_id, provider_record_id)
      when is_binary(provider) and not is_nil(config_id) and is_binary(provider_record_id) do
    source = data_source_record_source(provider, to_string(config_id), provider_record_id)

    case Document.get_by_source(source) do
      %Document{watch_status: status} = doc when status in ["pending", "watched"] ->
        %{status: status || "watched", error: doc.watch_error}

      _ ->
        nil
    end
  end

  def data_source_inherited_watch(_provider, _config_id, _provider_record_id), do: nil

  @doc "Returns BO-facing watch display state for a document plus inherited watch state."
  def data_source_record_watch_state(doc, inherited_watch)

  def data_source_record_watch_state(nil, inherited_watch) do
    %{
      watch_status: inherited_watch_status(inherited_watch),
      watch_error: inherited_watch_error(inherited_watch),
      watch_inherited?: inherited_watch_active?(inherited_watch)
    }
  end

  def data_source_record_watch_state(%Document{} = doc, inherited_watch) do
    %{
      watch_status: data_source_record_watch_status(doc, inherited_watch),
      watch_error: doc.watch_error || inherited_watch_error(inherited_watch),
      watch_inherited?: data_source_record_watch_inherited?(doc, inherited_watch)
    }
  end

  @doc "Returns whether a BO-facing watch state should be treated as active."
  def data_source_record_watch_active?(%{watch_status: status}),
    do: status in ["pending", "watched"]

  def data_source_record_watch_active?(_state), do: false

  @doc "Marks a watched target active after provider watch setup succeeds."
  def mark_watch_active(%{source: source} = target, watch_metadata) when is_binary(source) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = watch_active_attrs(watch_metadata, now)

    case Document.get_by_source(source) do
      %Document{} = doc -> update_document_watch(doc, attrs)
      nil -> maybe_insert_folder_watch_target(target, attrs)
    end
  end

  def mark_watch_active(_target, _watch_metadata), do: :skip

  @doc "Marks a watched target errored after provider watch setup fails."
  def mark_watch_error(%{source: source}, reason) when is_binary(source) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Document.get_by_source(source) do
      %Document{} = doc -> update_document_watch(doc, watch_error_attrs(reason, now))
      nil -> :skip
    end
  end

  def mark_watch_error(_target, _reason), do: :skip

  defp set_watch_status(targets, status) when status in ["pending", "unwatched"] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.reduce(targets, %{updated: 0, skipped: 0}, fn target, acc ->
      case update_watch_target(target, status, now) do
        {:ok, _doc} -> %{acc | updated: acc.updated + 1}
        :skip -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  defp update_watch_target(%{source: source} = target, status, now) when is_binary(source) do
    attrs = watch_status_attrs(status, now)

    case Document.get_by_source(source) do
      %Document{} = doc ->
        update_document_watch(doc, attrs)

      nil ->
        maybe_insert_folder_watch_target(target, attrs)
    end
  end

  defp update_watch_target(_target, _status, _now), do: :skip

  defp maybe_insert_folder_watch_target(%{kind: :folder, source: source}, attrs) do
    metadata = Map.merge(%{"entry_type" => "folder"}, Map.get(attrs, :metadata, %{}))

    %{source: source, content: nil, metadata: metadata}
    |> Map.merge(attrs)
    |> Map.put(:metadata, metadata)
    |> Document.insert_new()
    |> case do
      {:ok, %Document{} = doc} -> {:ok, doc}
      _ -> :skip
    end
  end

  defp maybe_insert_folder_watch_target(_target, _attrs), do: :skip

  defp update_document_watch(%Document{} = doc, attrs) when is_map(attrs) do
    attrs = maybe_merge_watch_metadata(doc, attrs)

    doc
    |> Document.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, doc} -> {:ok, doc}
      {:error, _changeset} -> :skip
    end
  end

  defp maybe_merge_watch_metadata(%Document{} = doc, %{metadata: metadata} = attrs)
       when is_map(metadata) do
    Map.put(attrs, :metadata, Map.merge(doc.metadata || %{}, metadata))
  end

  defp maybe_merge_watch_metadata(_doc, attrs), do: attrs

  defp watch_active_attrs(_watch_metadata, now) do
    %{
      watch_status: "watched",
      watch_updated_at: now,
      watch_error: nil
    }
  end

  defp watch_error_attrs(reason, now) do
    %{
      watch_status: "error",
      watch_updated_at: now,
      watch_error: inspect(reason)
    }
  end

  defp watch_status_attrs("pending", now) do
    %{
      watch_status: "pending",
      watch_requested_at: now,
      watch_updated_at: now,
      watch_error: nil
    }
  end

  defp watch_status_attrs("unwatched", now) do
    %{
      watch_status: "unwatched",
      watch_updated_at: now,
      watch_error: nil
    }
  end

  @doc """
  Records a newly uploaded file in the documents table.
  Called immediately at upload time so the file browser sees it right away.
  """
  def track_upload(_volume_name, path) do
    {:ok, source} = SourcePath.absolute_to_source(path)
    Document.insert_new(%{source: source})
  end

  def delete_path(volume_name, path, type, volumes \\ nil) do
    DeleteService.delete_path(volume_name, path, type, volumes)
  end

  def delete_paths(volume_name, paths, volumes \\ nil) do
    DeleteService.delete_paths(volume_name, paths, volumes)
  end

  # --- Permissions ---

  def list_document_permissions(document_id) do
    resource_id = to_string(document_id)

    Permission
    |> where([p], p.resource_type == "document" and p.resource_id == ^resource_id)
    |> preload([:person, :team])
    |> Repo.all()
  end

  def count_document_permissions(document_ids) when is_list(document_ids) do
    resource_ids = document_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    Permission
    |> where([p], p.resource_type == "document" and p.resource_id in ^resource_ids)
    |> group_by([p], p.resource_id)
    |> select([p], {p.resource_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  def list_person_permissions(person_id) do
    perms =
      Permission
      |> where([p], p.person_id == ^person_id and p.resource_type == "document")
      |> Repo.all()

    doc_ids = Enum.map(perms, &String.to_integer(&1.resource_id))

    docs_by_id =
      Document
      |> where([d], d.id in ^doc_ids)
      |> Repo.all()
      |> Map.new(&{to_string(&1.id), &1})

    Enum.map(perms, fn perm -> %{perm | document: docs_by_id[perm.resource_id]} end)
  end

  def set_document_permission(document_id, type, target_id, access_rights)
      when type in [:person, :team] do
    resource_id = to_string(document_id)

    {conflict_fragment, attrs} =
      case type do
        :person ->
          {"(resource_type, resource_id, person_id) WHERE person_id IS NOT NULL",
           %{
             resource_id: resource_id,
             person_id: target_id,
             access_rights: access_rights
           }}

        :team ->
          {"(resource_type, resource_id, team_id) WHERE team_id IS NOT NULL",
           %{
             resource_id: resource_id,
             team_id: target_id,
             access_rights: access_rights
           }}
      end

    now = DateTime.utc_now(:second)

    Repo.insert(
      Permission.changeset(%Permission{}, attrs),
      on_conflict: [set: [access_rights: access_rights, updated_at: now]],
      conflict_target: {:unsafe_fragment, conflict_fragment}
    )
  end

  def delete_document_permission(permission_id) do
    case Repo.get(Permission, permission_id) do
      nil -> {:error, :not_found}
      perm -> Repo.delete(perm)
    end
  end

  @doc """
  Returns the unique set of person/team permissions across all documents under
  the given folder. Deduplicates by person_id / team_id — one entry per target.

  **Note:** permissions are point-in-time snapshots of existing documents.
  Files added to the folder after permissions are set are not automatically
  covered — callers must re-apply folder permissions to include new documents.
  """
  def list_folder_permissions(volume_name, folder_path) do
    docs = list_documents_under_folder(volume_name, folder_path)
    doc_ids = Enum.map(docs, & &1.id)

    id_strings = Enum.map(doc_ids, &to_string/1)

    Permission
    |> where([p], p.resource_type == "document" and p.resource_id in ^id_strings)
    |> preload([:person, :team])
    |> Repo.all()
    |> Enum.uniq_by(fn p ->
      if p.person_id, do: {:person, p.person_id}, else: {:team, p.team_id}
    end)
  end

  @doc """
  Deletes all permissions for the same person or team target (identified by
  `permission_id`) across every document under the given folder.
  """
  def delete_folder_target_permission(volume_name, folder_path, permission_id) do
    docs = list_documents_under_folder(volume_name, folder_path)
    doc_ids = Enum.map(docs, & &1.id)

    case Repo.get(Permission, permission_id) do
      nil ->
        {:error, :not_found}

      perm ->
        id_strings = Enum.map(doc_ids, &to_string/1)

        filter =
          if perm.person_id,
            do:
              dynamic(
                [p],
                p.resource_type == "document" and p.resource_id in ^id_strings and
                  p.person_id == ^perm.person_id
              ),
            else:
              dynamic(
                [p],
                p.resource_type == "document" and p.resource_id in ^id_strings and
                  p.team_id == ^perm.team_id
              )

        {count, _} = Permission |> where(^filter) |> Repo.delete_all()
        {:ok, count}
    end
  end

  @doc """
  Returns all documents whose source lives under the given folder.

  Accepts a list of source prefixes (legacy + volume-prefixed) and returns
  documents matching any of them.
  """
  def list_documents_under_folder(volume_name, folder_path) do
    prefixes = SourcePath.source_candidates(volume_name, folder_path)
    conditions = Document.source_prefix_conditions(prefixes)

    from(d in Document, where: ^conditions)
    |> Repo.all()
  end

  # --- Document tag management ---

  @doc "Adds a tag to a document. No-op if the tag is already present."
  def add_document_tag(doc_id, tag) do
    from(d in Document,
      where: d.id == ^doc_id,
      where: not fragment("? @> ARRAY[?]::varchar[]", d.tags, ^tag),
      update: [set: [tags: fragment("array_append(?, ?)", d.tags, ^tag)]]
    )
    |> Repo.update_all([])

    {:ok, Repo.get!(Document, doc_id)}
  end

  @doc "Removes a tag from a document. No-op if the tag is not present."
  def remove_document_tag(doc_id, tag) do
    doc = Repo.get!(Document, doc_id)

    doc
    |> Ecto.Changeset.change(tags: List.delete(doc.tags, tag))
    |> Repo.update()
  end

  # --- Folder public flag ---

  @doc """
  Marks a folder public: persists the flag in `folder_settings` and adds the
  `"public"` tag to every document whose source starts with any known prefix
  for the folder (covers both volume-prefixed and legacy sources).
  """
  def set_folder_public(volume_name, folder_path) do
    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} =
          FolderSetting.upsert(%{
            volume_name: volume_name,
            folder_path: folder_path,
            tags: ["public"]
          })

        conditions =
          Document.source_prefix_conditions(
            SourcePath.source_candidates(volume_name, folder_path)
          )

        from(d in Document,
          where: ^conditions,
          where: not fragment("? @> ARRAY[?]::varchar[]", d.tags, "public"),
          update: [set: [tags: fragment("array_append(?, ?)", d.tags, "public")]]
        )
        |> Repo.update_all([])
      end)

    :ok
  end

  @doc """
  Removes the public flag from a folder and strips the `"public"` tag from all
  documents under it.
  """
  def unset_folder_public(volume_name, folder_path) do
    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} =
          FolderSetting.upsert(%{volume_name: volume_name, folder_path: folder_path, tags: []})

        conditions =
          Document.source_prefix_conditions(
            SourcePath.source_candidates(volume_name, folder_path)
          )

        from(d in Document,
          where: ^conditions,
          where: fragment("? @> ARRAY[?]::varchar[]", d.tags, "public"),
          update: [set: [tags: fragment("array_remove(?, ?)", d.tags, "public")]]
        )
        |> Repo.update_all([])
      end)

    :ok
  end

  @doc "Returns true if the folder has the `\"public\"` tag set."
  def folder_public?(volume_name, folder_path) do
    case FolderSetting.get(volume_name, folder_path) do
      nil -> false
      setting -> "public" in setting.tags
    end
  end

  def get_document_by_source!(source) do
    Document.get_by_source(source) ||
      raise "Document not found for source: #{source}"
  end

  # --- Job queries ---

  def list_jobs(opts \\ []) do
    status = Keyword.get(opts, :status)
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    IngestJob
    |> maybe_filter_status(status)
    |> order_by(desc: :inserted_at)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  def get_job(id), do: Repo.get(IngestJob, id)

  # --- Job actions ---

  def retry_job(id) do
    with %IngestJob{} = job <- Repo.get(IngestJob, id),
         :ok <- ensure_retryable(job),
         original_status = job.status,
         {:ok, updated_job} <-
           JobLifecycle.transition(job, %{status: "pending", error: nil, completed_at: nil}) do
      retry_args =
        if original_status == "completed_with_errors" do
          %{"job_id" => updated_job.id, "retry_failed_chunks" => true}
        else
          %{"job_id" => updated_job.id}
        end

      retry_args
      |> IngestWorker.new()
      |> Oban.insert()

      {:ok, updated_job}
    else
      {:error, :not_retryable} -> {:error, :not_failed}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp ensure_retryable(%IngestJob{status: "failed"}), do: :ok

  defp ensure_retryable(%IngestJob{status: "completed_with_errors", failed_chunks: failed_chunks})
       when failed_chunks > 0,
       do: :ok

  defp ensure_retryable(_), do: {:error, :not_retryable}

  def cancel_job(id) do
    case Repo.get(IngestJob, id) do
      %IngestJob{status: status} = job when status in ["pending", "processing"] ->
        stop_job(job, "Cancelled by user.")

      %IngestJob{} ->
        {:error, :not_cancellable}

      nil ->
        {:error, :not_found}
    end
  end

  def abort_job(%IngestJob{} = job, error_message) do
    stop_job(job, error_message)
  end

  defp stop_job(job, error_message) do
    Repo.transaction(fn ->
      cancel_chunk_oban_jobs(job.id)
      terminate_chunk_jobs(job.id, error_message)

      case JobLifecycle.mark_failed(job, error_message) do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp cancel_chunk_oban_jobs(ingest_job_id) do
    {count, _} =
      from(j in Oban.Job,
        where: j.queue == "ingestion_chunks",
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("?->>'job_id' = ?", j.args, ^to_string(ingest_job_id))
      )
      |> Repo.update_all(set: [state: "cancelled"])

    Logger.info("[Ingestion] Cancelled #{count} Oban chunk jobs for ingest_job=#{ingest_job_id}")
    :ok
  end

  defp terminate_chunk_jobs(ingest_job_id, error_message) do
    from(c in IngestChunkJob,
      where: c.ingest_job_id == ^ingest_job_id,
      where: c.status in ["pending", "processing"]
    )
    |> Repo.update_all(set: [status: "failed_final", error: error_message])

    :ok
  end

  # --- PubSub ---

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  # --- Private ---

  defp ingest_file_record(record, mode) do
    volume = RecordSource.volume(record)

    with path when is_binary(path) <- RecordSource.job_path(record),
         {:ok, job} <- create_job(path, mode, volume, RecordSource.to_storage_map(record)) do
      run_job(job, mode)
    else
      _ -> {:error, :unsupported_record_source}
    end
  end

  defp collect_ingest_result(record, mode, {jobs, errors}) do
    case ingest_record(record, mode) do
      {:ok, record_jobs} when is_list(record_jobs) ->
        {Enum.reverse(record_jobs) ++ jobs, errors}

      {:ok, job} ->
        {[job | jobs], errors}

      {:error, {:partial_failure, record_jobs, record_errors}} ->
        {Enum.reverse(record_jobs) ++ jobs, Enum.reverse(record_errors) ++ errors}

      {:error, reason} ->
        {jobs, [%{record: record_error_ref(record), reason: reason} | errors]}
    end
  end

  defp record_error_ref(%{id: id, name: name}), do: %{id: id, name: name}
  defp record_error_ref(record), do: inspect(record)

  defp changed_records_from_request(request) do
    explicit_records = request |> read_any([:records, "records"]) |> List.wrap()

    signal_records =
      request
      |> read_any([:signals, "signals"])
      |> List.wrap()
      |> Enum.reject(&data_source_signal_removed?/1)
      |> Enum.map(&data_source_signal_record(&1, false))

    (explicit_records ++ signal_records)
    |> Enum.map(&normalize_data_source_record/1)
    |> Enum.reject(&is_nil/1)
  end

  defp watched_data_source_record?(%Record{} = record, provider, config_id) do
    source = data_source_record_source(provider, config_id, record.id)

    if is_binary(source) do
      state =
        source
        |> Document.get_by_source()
        |> data_source_record_watch_state(
          inherited_watch_for_parent_ids(provider, config_id, record.parent_ids)
        )

      data_source_record_watch_active?(state)
    else
      false
    end
  end

  defp watched_data_source_record?(_record, _provider, _config_id), do: false

  defp log_ignored_data_source_changes([], _provider, _config_id), do: :ok

  defp log_ignored_data_source_changes(records, provider, config_id) do
    ignored =
      Enum.map(records, fn %Record{} = record ->
        %{id: record.id, parent_ids: record.parent_ids || []}
      end)

    Logger.info(
      "[Ingestion] Ignored unwatched data-source changes " <>
        inspect(%{provider: provider, config_id: config_id, records: ignored})
    )
  end

  defp data_source_record_watch_status(%Document{watch_status: status}, _inherited_watch)
       when status in ["pending", "watched", "error"],
       do: status

  defp data_source_record_watch_status(_doc, inherited_watch),
    do: inherited_watch_status(inherited_watch)

  defp data_source_record_watch_inherited?(%Document{watch_status: status}, inherited_watch) do
    status not in ["pending", "watched", "error"] and inherited_watch_active?(inherited_watch)
  end

  defp inherited_watch_for_parent_ids(provider, config_id, parent_ids) do
    parent_ids
    |> List.wrap()
    |> Enum.find_value(&data_source_inherited_watch(provider, config_id, &1))
  end

  defp inherited_watch_status(%{status: status}) when status in ["pending", "watched"], do: status
  defp inherited_watch_status(_), do: "unwatched"

  defp inherited_watch_error(%{error: error}), do: error
  defp inherited_watch_error(_), do: nil

  defp inherited_watch_active?(%{status: status}), do: status in ["pending", "watched"]
  defp inherited_watch_active?(_), do: false

  defp data_source_record_source(provider, config_id, provider_record_id)
       when is_binary(provider) and is_binary(config_id) and is_binary(provider_record_id) do
    Enum.join(["data_source", provider, config_id, provider_record_id], "/")
  end

  defp data_source_record_source(_provider, _config_id, _provider_record_id), do: nil

  defp delete_removed_data_source_documents(request, provider, config_id) do
    request
    |> read_any([:signals, "signals"])
    |> List.wrap()
    |> Enum.filter(&data_source_signal_removed?/1)
    |> Enum.map(&data_source_signal_record/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(0, fn record, count ->
      count + delete_data_source_documents(provider, config_id, record)
    end)
  end

  defp delete_data_source_documents(provider, config_id, %Record{} = record)
       when is_binary(provider) and is_binary(config_id) do
    source = data_source_record_source(provider, config_id, record.id)
    doc = Document.get_by_source(source)

    parent_ids = data_source_document_parent_ids(doc, record.parent_ids)
    inherited_watch = inherited_watch_for_parent_ids(provider, config_id, parent_ids)
    state = data_source_record_watch_state(doc, inherited_watch)

    if data_source_record_watch_active?(state) do
      delete_data_source_document_sources(source, doc)
    else
      0
    end
  end

  defp delete_data_source_documents(_provider, _config_id, _record), do: 0

  defp delete_data_source_document_sources(_source, nil), do: 0

  defp delete_data_source_document_sources(source, %Document{} = doc) do
    sidecar_source = Sidecar.sidecar_source(doc) || source <> ".md"
    sidecar_doc = Document.get_by_source(sidecar_source)

    delete_external_sidecar_file(sidecar_doc)

    [doc, sidecar_doc]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(0, fn doc, count -> count + delete_existing_data_source_document(doc) end)
  end

  defp data_source_document_parent_ids(%Document{metadata: metadata}, fallback_parent_ids) do
    persisted_parent_ids =
      case read_any(metadata || %{}, ["provider_parent_ids", :provider_parent_ids]) do
        parent_ids when is_list(parent_ids) -> Enum.filter(parent_ids, &is_binary/1)
        _ -> []
      end

    persisted_parent_id =
      read_stringish(metadata || %{}, ["provider_parent_id", :provider_parent_id])

    (persisted_parent_ids ++ List.wrap(persisted_parent_id) ++ List.wrap(fallback_parent_ids))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp data_source_document_parent_ids(nil, fallback_parent_ids) do
    fallback_parent_ids
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp delete_external_sidecar_file(nil), do: :ok

  defp delete_external_sidecar_file(%Document{} = sidecar_doc) do
    sidecar_doc.metadata
    |> read_stringish(["sidecar_file_path", :sidecar_file_path])
    |> delete_external_sidecar_relative_path()
  end

  defp delete_external_sidecar_relative_path(path) when is_binary(path) do
    if path |> Path.split() |> Enum.member?(".external-sidecars") do
      case FileExplorer.delete(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp delete_external_sidecar_relative_path(_path), do: :ok

  defp delete_existing_data_source_document(%Document{} = doc) do
    case Document.delete(doc) do
      {:ok, _doc} -> 1
      _ -> 0
    end
  end

  defp data_source_signal_removed?(signal) when is_map(signal) do
    read_any(signal, [:removed?, "removed?", :removed, "removed", :deleted, "deleted"]) == true or
      read_any(signal, [:change_type, "change_type"]) in [:deleted, "deleted"]
  end

  defp data_source_signal_removed?(_signal), do: false

  defp data_source_signal_record(signal), do: data_source_signal_record(signal, true)

  defp data_source_signal_record(signal, use_fallback_id?) when is_map(signal) do
    record = read_any(signal, [:record, "record"])

    provider_record_id =
      if use_fallback_id? do
        read_stringish(signal, [:provider_record_id, "provider_record_id", :id, "id"])
      end

    record
    |> normalize_data_source_record(provider_record_id)
    |> maybe_apply_signal_change(signal)
  end

  defp data_source_signal_record(_signal, _use_fallback_id?), do: nil

  defp normalize_data_source_record(%Record{} = record), do: record
  defp normalize_data_source_record(record), do: normalize_data_source_record(record, nil)

  defp normalize_data_source_record(%Record{} = record, _fallback_id), do: record

  defp normalize_data_source_record(record, fallback_id) when is_map(record) do
    id =
      read_stringish(record, [:id, "id", :provider_record_id, "provider_record_id"]) ||
        fallback_id

    if is_binary(id) do
      %Record{
        id: id,
        kind: data_source_record_kind(record),
        name: read_stringish(record, [:name, "name"]),
        mime_type: read_stringish(record, [:mime_type, "mime_type", :mimeType, "mimeType"]),
        url:
          read_stringish(record, [:web_url, "web_url", :url, "url", :webViewLink, "webViewLink"]),
        parent_ids: read_any(record, [:parents, "parents", :parent_ids, "parent_ids"]) || [],
        raw: record,
        attributes: %{}
      }
    end
  end

  defp normalize_data_source_record(_record, fallback_id) when is_binary(fallback_id) do
    %Record{id: fallback_id, kind: :file, raw: %{}, attributes: %{}}
  end

  defp normalize_data_source_record(_record, _fallback_id), do: nil

  defp maybe_apply_signal_change(nil, _signal), do: nil

  defp maybe_apply_signal_change(%Record{} = record, signal) when is_map(signal) do
    case read_any(signal, [:change_type, "change_type"]) do
      change_type when change_type in [:deleted, "deleted"] ->
        %{
          record
          | change_type: :deleted,
            lifecycle_state: :deleted,
            deleted_at: DateTime.utc_now(:second)
        }

      change_type when is_atom(change_type) ->
        %{record | change_type: change_type, lifecycle_state: :active}

      change_type when is_binary(change_type) ->
        %{record | change_type: String.to_existing_atom(change_type), lifecycle_state: :active}
    end
  rescue
    ArgumentError -> %{record | lifecycle_state: :active}
  end

  defp data_source_record_kind(record) do
    kind = read_any(record, [:kind, "kind"])
    mime_type = read_stringish(record, [:mime_type, "mime_type", :mimeType, "mimeType"])

    cond do
      kind in [:folder, "folder", :collection, "collection"] -> :folder
      mime_type == "application/vnd.google-apps.folder" -> :folder
      true -> :file
    end
  end

  defp put_data_source_attrs(%Record{} = record, provider, config_id) do
    attrs =
      (record.attributes || %{})
      |> maybe_put_attr("provider", provider)
      |> maybe_put_attr("config_id", config_id)
      |> Map.put_new("provider_record_id", record.id)

    %{record | attributes: attrs}
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put_new(attrs, key, to_string(value))

  defp read_stringish(map, keys) do
    MapUtils.read_present_stringish(map, keys)
  end

  defp read_any(map, keys), do: MapUtils.read_present(map, keys)

  defp create_job(path, mode, volume_name, source_record) do
    attrs =
      %{file_path: path, status: "pending", mode: to_string(mode), source_record: source_record}
      |> then(fn a -> if volume_name, do: Map.put(a, :volume_name, volume_name), else: a end)

    %IngestJob{}
    |> IngestJob.changeset(attrs)
    |> Repo.insert()
  end

  defp run_job(job, mode) do
    case mode do
      :async ->
        %{"job_id" => job.id}
        |> IngestWorker.new()
        |> Oban.insert()

        {:ok, job}

      :inline ->
        IngestWorker.perform(%Oban.Job{args: %{"job_id" => job.id}})
        {:ok, Repo.get!(IngestJob, job.id)}
    end
  end

  defp normalize_mode(:inline), do: :inline
  defp normalize_mode("inline"), do: :inline
  defp normalize_mode(_), do: :async

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, statuses) when is_list(statuses),
    do: where(query, [j], j.status in ^statuses)

  defp maybe_filter_status(query, status), do: where(query, [j], j.status == ^status)
end
