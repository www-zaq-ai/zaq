defmodule Zaq.Ingestion do
  @moduledoc """
  Public API for coordinating ingestion: trigger inline or async ingestion,
  query job statuses, retry and cancel jobs.

  Ingestion also owns user-facing document watch state and provider delta
  handling. Channels/Engine provide metadata-only provider changes; this context
  decides which watched records should be re-ingested, which removed records
  should delete existing documents, and how folder watch inheritance
  is reflected in the BO UI.

  ## Records are not produced here

  Disk data-source records are produced by `Zaq.Channels.DiskBridge` over the Storage role.
  Ingestion still consumes records — `ingest_records/2` takes them from any bridge — and that
  knowledge is confined to `Zaq.Ingestion.RecordSource` and `Zaq.Ingestion.ExternalSource`.

  `RecordSource.from_entries/1` produces records too, but
  only as ingest-pipeline input, which is why they carry no `materialization_handle`.

  ## A file is named by its source

  Every indexed document keeps a `Document.source` — provider or storage identity plus relative
  path — not a filesystem handle. Storage-owned entries do not carry `documents.id`; indexed
  state is reported through provider-neutral enrichment queries instead of being embedded in
  bridge payloads.

  BO local browsing goes through `Zaq.Channels.DiskBridge`; Ingestion only enriches and
  ingests canonical records.
  """

  alias Zaq.Ingestion.{
    Chunk,
    ContentSource,
    Document,
    ExternalSource,
    IngestChunkJob,
    IngestJob,
    IngestWorker,
    JobLifecycle,
    RecordSource
  }

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Permissions
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
    context = materialization_context(params)

    {jobs, errors} = Enum.reduce(records, {[], []}, &collect_ingest_result(&1, mode, context, &2))

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
  ingestion. Removed records delete matching source documents and chunks when
  the watch state permits deletion.
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
    ingest_record_with_context(record, mode, %{})
  end

  defp ingest_record_with_context(record, mode, context) do
    case RecordSource.kind(record) do
      :file ->
        ingest_file_record(record, mode, context)

      :folder ->
        with {:ok, children} <- RecordSource.list_children(record, context) do
          ingest_records(children, Map.put(context, :mode, mode))
        end

      _ ->
        {:error, :unsupported_record_kind}
    end
  end

  # --- Content filter autocomplete ---

  @doc """
  Returns up to 50 `%ContentSource{}` structs for the @ mention autocomplete.

  When `query` is given, only indexed document sources matching the query string are returned.

  Called via `NodeRouter.dispatch/1` with `%Zaq.Event{}` targeting ingestion role.
  Never call this directly from BO — use the NodeRouter boundary.
  """
  def list_document_sources(query \\ nil) do
    query
    |> list_db_sources()
    |> Enum.uniq_by(& &1.source_prefix)
    |> Enum.take(50)
  end

  @doc "Returns provider-neutral indexed-state enrichment for canonical data-source records."
  @spec enrich_records([Record.t()]) :: {:ok, map()}
  def enrich_records(records) when is_list(records) do
    chunks_table_exists? = Chunk.table_exists?()

    documents_by_source =
      records
      |> Enum.map(&record_source_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Document.list_by_sources()
      |> Map.new(&{&1.source, &1})

    permission_counts =
      documents_by_source
      |> Map.values()
      |> Enum.map(& &1.id)
      |> count_document_permissions()

    statuses =
      records
      |> Enum.map(&record_source_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn source ->
        {source,
         record_status(
           source,
           Map.get(documents_by_source, source),
           permission_counts,
           chunks_table_exists?
         )}
      end)

    {:ok, statuses}
  end

  defp record_source_key(%Record{} = record) do
    if ExternalSource.external?(record) do
      ExternalSource.source(record)
    else
      attr(record, "source") || attr(record, :source) || record.id
    end
  end

  defp record_status(_source, document, permission_counts, chunks_table_exists?) do
    case document do
      %Document{} = document ->
        indexed? =
          chunks_table_exists? and
            Repo.exists?(from c in Chunk, where: c.document_id == ^document.id)

        %{
          document_id: document.id,
          indexed?: indexed?,
          ingested_at: if(indexed?, do: document.updated_at),
          permissions_count: Map.get(permission_counts, to_string(document.id), 0),
          watch_status: document.watch_status,
          watch_error: document.watch_error,
          public?: Permissions.public?(document)
        }

      nil ->
        %{
          document_id: nil,
          indexed?: false,
          ingested_at: nil,
          permissions_count: 0,
          watch_status: nil,
          watch_error: nil,
          public?: false
        }
    end
  end

  defp attr(%Record{attributes: attrs}, key) when is_map(attrs), do: Map.get(attrs, key)
  defp attr(%Record{}, _key), do: nil

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
            ilike(d.source, ^"%#{name}%")
          ),
        else: dynamic([_d], true)

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
          where: like(d.source, ^"#{prefix}%"),
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
        ilike(d.source, ^"#{folder_label}/%") or
          ilike(d.source, ^"%/#{folder_label}/%"),
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
  - Documents granted to the system Everyone team are accessible to all.
  - Documents with no permission rows are private (admin-only).
  - Otherwise: person must have a direct permission or a team permission.
  """
  def can_access_file?(relative_path, current_user) do
    source = normalize_source_path(relative_path)

    case Document.get_by_source(source) do
      nil ->
        true

      doc ->
        super_admin? = current_user.role.name == "super_admin"
        person_id = Map.get(current_user, :person_id)

        person =
          case person_id && Repo.get(Zaq.Accounts.Person, person_id) do
            nil -> nil
            person -> %{person | team_ids: Map.get(current_user, :team_ids) || person.team_ids}
          end

        Permissions.can?(person, :read, doc, skip_permissions: super_admin?)
    end
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

  # --- Permissions ---

  def list_document_permissions(document_id) do
    resource_id = to_string(document_id)

    Permission
    |> where([p], p.resource_type == "document" and p.resource_id == ^resource_id)
    |> preload([:person, :team])
    |> Repo.all()
  end

  @doc "Replaces source permissions through Channels and synchronizes matching documents."
  def sync_data_source_permissions(provider, params, context \\ %{})
      when is_map(params) and is_map(context) do
    with {:ok, %{affected_file_ids: affected_file_ids} = result} <-
           replace_source_permissions(provider, params, context),
         :ok <- sync_data_source_documents(provider, params, affected_file_ids, context) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
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

  defp replace_source_permissions(provider, params, context) do
    params
    |> Event.new(:channels,
      opts: [action: :data_source_replace_permissions],
      actor: Map.get(context, :actor) || Map.get(context, "actor")
    )
    |> then(fn event -> %{event | request: %{provider: provider, params: params}} end)
    |> node_router(context).dispatch()
    |> Map.get(:response)
  end

  defp sync_data_source_documents(provider, params, file_ids, context) do
    config_id = Map.get(params, "config_id") || Map.get(params, :config_id)

    Enum.reduce_while(file_ids, :ok, fn file_id, :ok ->
      sync_data_source_document(provider, config_id, params, file_id, context)
    end)
  end

  defp sync_data_source_document(provider, config_id, params, file_id, context) do
    source =
      data_source_record_source(to_string(provider), to_string(config_id), to_string(file_id))

    case Document.get_by_source(source) do
      nil ->
        {:cont, :ok}

      %Document{} = document ->
        replace_document_permissions(document, provider, params, file_id, context)
    end
  end

  defp replace_document_permissions(document, provider, params, file_id, context) do
    with {:ok, grants} <- list_source_permission_records(provider, params, file_id, context),
         {:ok, _} <- Permissions.replace(document, document_grants(grants)) do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, {:document_sync_failed, file_id, reason}}}
      other -> {:halt, {:error, {:document_sync_failed, file_id, other}}}
    end
  end

  defp list_source_permission_records(provider, params, file_id, context) do
    request_params = Map.put(params, "file_id", file_id)

    response =
      %{provider: provider, params: request_params}
      |> Event.new(:channels,
        opts: [action: :data_source_list_permissions],
        actor: Map.get(context, :actor) || Map.get(context, "actor")
      )
      |> node_router().dispatch()
      |> Map.get(:response)

    case response do
      {:ok, %{records: records}} when is_list(records) -> {:ok, records}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp document_grants(records) do
    records
    |> Enum.map(&document_grant/1)
    |> Enum.reject(&is_nil/1)
  end

  defp document_grant(%Record{attributes: %{"type" => "public"}}),
    do: %{team_id: Permissions.everyone_team_id(), access_rights: ["read"]}

  defp document_grant(%Record{attributes: %{"type" => "person", "target_id" => id} = attrs}),
    do: %{person_id: parse_int(id), access_rights: Map.get(attrs, "access_rights", ["read"])}

  defp document_grant(%Record{attributes: %{"type" => "team", "target_id" => id} = attrs}),
    do: %{team_id: parse_int(id), access_rights: Map.get(attrs, "access_rights", ["read"])}

  defp document_grant(_record), do: nil

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_binary(value), do: String.to_integer(value)

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
    prefixes = source_candidates(volume_name, folder_path)
    conditions = Document.source_prefix_conditions(prefixes)

    from(d in Document, where: ^conditions)
    |> Repo.all()
  end

  def get_document_by_source!(source) do
    Document.get_by_source(source) ||
      raise "Document not found for source: #{source}"
  end

  defp source_candidates(nil, folder_path), do: [normalize_source_path(folder_path)]

  defp source_candidates(volume_name, folder_path) do
    normalized = normalize_source_path(folder_path)

    [normalized, Path.join(to_string(volume_name), normalized)]
    |> Enum.uniq()
  end

  defp normalize_source_path(path) when is_binary(path) do
    path
    |> Path.expand("/")
    |> Path.relative_to("/")
    |> case do
      "" -> "."
      normalized -> normalized
    end
  end

  defp normalize_source_path(_path), do: "."

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

  defp ingest_file_record(record, mode, context) do
    with path when is_binary(path) <- RecordSource.job_path(record),
         {:ok, job} <- create_job(path, mode, nil, source_record_for_job(record, context)) do
      run_job(job, mode)
    else
      _ -> {:error, :unsupported_record_source}
    end
  end

  defp collect_ingest_result(record, mode, context, {jobs, errors}) do
    case ingest_record_with_context(record, mode, context) do
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

  defp materialization_context(params) do
    %{}
    |> maybe_put_context(:actor, Map.get(params, :actor) || Map.get(params, "actor"))
    |> maybe_put_context(
      :node_router,
      Map.get(params, :node_router) || Map.get(params, "node_router")
    )
  end

  defp source_record_for_job(record, context) do
    record
    |> RecordSource.to_storage_map()
    |> maybe_put_materialization_context(context)
  end

  defp maybe_put_materialization_context(source_record, context) when map_size(context) > 0,
    do: Map.put(source_record, "materialization_context", context)

  defp maybe_put_materialization_context(source_record, _context), do: source_record

  defp maybe_put_context(context, :actor, actor) when is_map(actor),
    do: Map.put(context, :actor, actor)

  defp maybe_put_context(context, :node_router, node_router) when is_atom(node_router),
    do: Map.put(context, :node_router, node_router)

  defp maybe_put_context(context, _key, _value), do: context

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
    force_delete? = read_any(request, [:force_delete, "force_delete"]) == true

    request
    |> read_any([:signals, "signals"])
    |> List.wrap()
    |> Enum.filter(&data_source_signal_removed?/1)
    |> Enum.map(&data_source_signal_record/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&put_data_source_attrs(&1, provider, config_id))
    |> Enum.reduce(0, fn record, count ->
      count + delete_data_source_documents(provider, config_id, record, force_delete?)
    end)
  end

  defp delete_data_source_documents(provider, config_id, %Record{} = record, force_delete?)
       when is_binary(provider) and is_binary(config_id) do
    source = ExternalSource.source(record)
    doc = Document.get_by_source(source)

    delete_data_source_documents_for(source, doc, record, force_delete?)
  end

  defp delete_data_source_documents(_provider, _config_id, _record, _force_delete?), do: 0

  defp delete_data_source_documents_for(_source, nil, %Record{id: parent_id}, _force_delete?)
       when is_binary(parent_id) do
    Document
    |> where(
      [d],
      fragment("? @> ?", d.metadata, ^%{"provider_parent_ids" => [parent_id]}) or
        fragment("? @> ?", d.metadata, ^%{"provider_parent_id" => parent_id})
    )
    |> Repo.all()
    |> Enum.reduce(0, fn doc, count -> count + delete_existing_data_source_document(doc) end)
  end

  defp delete_data_source_documents_for(_source, nil, _record, _force_delete?), do: 0

  defp delete_data_source_documents_for(_source, %Document{} = doc, _record, force_delete?) do
    if force_delete? or removable_data_source_document?(doc) do
      delete_existing_data_source_document(doc)
    else
      0
    end
  end

  defp removable_data_source_document?(%Document{watch_status: status})
       when status in ["pending", "watched"],
       do: true

  defp removable_data_source_document?(%Document{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("provider_parent_ids", [])
    |> List.wrap()
    |> Enum.any?(&watched_data_source_folder?/1)
  end

  defp removable_data_source_document?(_doc), do: false

  defp watched_data_source_folder?(parent_id) when is_binary(parent_id) and parent_id != "" do
    Document
    |> where([d], d.watch_status in ["pending", "watched"])
    |> where([d], fragment("? @> ?", d.metadata, ^%{"entry_type" => "folder"}))
    |> where([d], like(d.source, ^"%/#{parent_id}"))
    |> Repo.exists?()
  end

  defp watched_data_source_folder?(_parent_id), do: false

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

  defp node_router, do: Zaq.NodeRouter

  defp node_router(%{} = context),
    do: Map.get(context, :node_router) || Map.get(context, "node_router") || Zaq.NodeRouter

  defp node_router(_context), do: Zaq.NodeRouter
end
