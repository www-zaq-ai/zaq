defmodule Zaq.Ingestion do
  @moduledoc """
  Public API for coordinating ingestion: trigger inline or async ingestion,
  query job statuses, retry and cancel jobs.
  """

  alias Zaq.Ingestion.{
    DeleteService,
    DirectorySnapshot,
    Document,
    FileExplorer,
    FolderSetting,
    IngestJob,
    IngestWorker,
    JobLifecycle,
    Permission,
    RenameService,
    SourcePath
  }

  alias Zaq.Repo

  import Ecto.Query

  @pubsub Zaq.PubSub
  @topic "ingestion:jobs"

  # --- Ingestion triggers ---

  def ingest_file(path, mode \\ :async, volume_name \\ nil) do
    with {:ok, job} <- create_job(path, mode, volume_name) do
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
  end

  def ingest_folder(path, mode \\ :async, volume_name \\ nil) do
    with {:ok, entries} <- list_in_volume(volume_name, path) do
      jobs =
        entries
        |> Enum.filter(&(&1.type == :file))
        |> Enum.map(fn entry ->
          file_path = Path.join(path, entry.name)
          {:ok, job} = ingest_file(file_path, mode, volume_name)
          job
        end)

      {:ok, jobs}
    end
  end

  # --- Access control ---

  @doc """
  Returns true if the given person can access a file at `relative_path`.
  - Super admins bypass all checks.
  - Files with no Document record are accessible to all (backward compat).
  - Files with no permissions set are accessible to all (public by default).
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

        super_admin? or permissions == [] or
          Enum.any?(permissions, fn p ->
            (not is_nil(p.person_id) and p.person_id == person_id) or
              (not is_nil(p.team_id) and p.team_id in team_ids)
          end)
    end
  end

  # --- Upload tracking ---

  def list_volumes, do: FileExplorer.list_volumes()

  def list_entries(volume_name, path), do: FileExplorer.list(volume_name, path)

  def create_directory(volume_name, path), do: FileExplorer.create_directory(volume_name, path)

  def rename_entry(volume_name, old_path, new_path),
    do: RenameService.rename_entry(volume_name, old_path, new_path)

  def upload_file(volume_name, path, content),
    do: FileExplorer.upload_unique(volume_name, path, content)

  def save_file(volume_name, path, content),
    do: FileExplorer.upload(volume_name, path, content)

  def file_info(volume_name, path), do: FileExplorer.file_info(volume_name, path)

  def directory_snapshot(volume_name, current_dir, current_user) do
    with {:ok, entries} <- list_entries(volume_name, current_dir) do
      sorted =
        entries
        |> Enum.sort_by(fn e -> {if(e.type == :directory, do: 0, else: 1), e.name} end)

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

  @doc """
  Records a newly uploaded file in the documents table.
  Called immediately at upload time so the file browser sees it right away.
  """
  def track_upload(volume_name, path) do
    source = SourcePath.build_source(volume_name, path)
    Document.upsert(%{source: source})
  end

  def delete_path(volume_name, path, type, volumes \\ nil) do
    DeleteService.delete_path(volume_name, path, type, volumes)
  end

  def delete_paths(volume_name, paths, volumes \\ nil) do
    DeleteService.delete_paths(volume_name, paths, volumes)
  end

  # --- Permissions ---

  def list_document_permissions(document_id) do
    Permission
    |> where([p], p.document_id == ^document_id)
    |> preload([:person, :team])
    |> Repo.all()
  end

  def list_person_permissions(person_id) do
    Permission
    |> where([p], p.person_id == ^person_id)
    |> preload(:document)
    |> Repo.all()
  end

  def set_document_permission(document_id, type, target_id, access_rights)
      when type in [:person, :team] do
    {conflict_fragment, attrs} =
      case type do
        :person ->
          {"(document_id, person_id) WHERE person_id IS NOT NULL",
           %{document_id: document_id, person_id: target_id, access_rights: access_rights}}

        :team ->
          {"(document_id, team_id) WHERE team_id IS NOT NULL",
           %{document_id: document_id, team_id: target_id, access_rights: access_rights}}
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

    Permission
    |> where([p], p.document_id in ^doc_ids)
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
        filter =
          if perm.person_id,
            do: dynamic([p], p.document_id in ^doc_ids and p.person_id == ^perm.person_id),
            else: dynamic([p], p.document_id in ^doc_ids and p.team_id == ^perm.team_id)

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

  def list_permitted_document_ids(person_id, team_ids, doc_ids) do
    via_permission =
      build_permission_query(person_id, team_ids, doc_ids)
      |> Repo.all()

    via_public =
      from(d in Document,
        where: d.id in ^doc_ids and fragment("? @> ARRAY[?]::varchar[]", d.tags, "public"),
        select: d.id
      )
      |> Repo.all()

    Enum.uniq(via_permission ++ via_public)
  end

  defp build_permission_query(nil, team_ids, _doc_ids) when team_ids == [] do
    from(p in Permission, where: false, select: p.document_id)
  end

  defp build_permission_query(nil, team_ids, doc_ids) do
    from(p in Permission,
      where: p.document_id in ^doc_ids and p.team_id in ^team_ids,
      select: p.document_id,
      distinct: true
    )
  end

  defp build_permission_query(person_id, team_ids, doc_ids) do
    from(p in Permission,
      where:
        p.document_id in ^doc_ids and
          (p.person_id == ^person_id or p.team_id in ^team_ids),
      select: p.document_id,
      distinct: true
    )
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
    with %IngestJob{status: "pending"} = job <- Repo.get(IngestJob, id),
         {:ok, job} <- JobLifecycle.mark_failed(job, "cancelled") do
      {:ok, job}
    else
      %IngestJob{} -> {:error, :not_pending}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # --- PubSub ---

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  # --- Private ---

  defp list_in_volume(nil, path), do: FileExplorer.list(path)
  defp list_in_volume(volume_name, path), do: FileExplorer.list(volume_name, path)

  defp create_job(path, mode, volume_name) do
    attrs =
      %{file_path: path, status: "pending", mode: to_string(mode)}
      |> then(fn a -> if volume_name, do: Map.put(a, :volume_name, volume_name), else: a end)

    %IngestJob{}
    |> IngestJob.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, statuses) when is_list(statuses),
    do: where(query, [j], j.status in ^statuses)

  defp maybe_filter_status(query, status), do: where(query, [j], j.status == ^status)
end
