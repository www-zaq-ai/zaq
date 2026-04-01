defmodule Zaq.Ingestion do
  @moduledoc """
  Public API for coordinating ingestion: trigger inline or async ingestion,
  query job statuses, retry and cancel jobs.
  """

  alias Zaq.Ingestion.{
    Chunk,
    DeleteService,
    DirectorySnapshot,
    Document,
    FileExplorer,
    IngestJob,
    IngestWorker,
    JobLifecycle,
    RenameService,
    SourcePath
  }

  alias Zaq.Repo

  import Ecto.Query

  @pubsub Zaq.PubSub
  @topic "ingestion:jobs"

  # --- Ingestion triggers ---

  def ingest_file(path, mode \\ :async, volume_name \\ nil, role_id \\ nil, shared_role_ids \\ []) do
    with {:ok, job} <- create_job(path, mode, volume_name, role_id, shared_role_ids) do
      case mode do
        :async ->
          job.id
          |> build_job_args(role_id, shared_role_ids)
          |> IngestWorker.new()
          |> Oban.insert()

          {:ok, job}

        :inline ->
          enqueue_inline_ingest(job, role_id, shared_role_ids)
      end
    end
  end

  defp enqueue_inline_ingest(job, role_id, shared_role_ids) do
    IngestWorker.perform(%Oban.Job{args: build_job_args(job.id, role_id, shared_role_ids)})

    {:ok, Repo.get!(IngestJob, job.id)}
  end

  defp build_job_args(job_id, role_id, shared_role_ids) do
    args = %{"job_id" => job_id}
    args = if role_id, do: Map.put(args, "role_id", role_id), else: args
    if shared_role_ids != [], do: Map.put(args, "shared_role_ids", shared_role_ids), else: args
  end

  def ingest_folder(
        path,
        mode \\ :async,
        volume_name \\ nil,
        role_id \\ nil,
        shared_role_ids \\ []
      ) do
    with {:ok, entries} <- list_in_volume(volume_name, path) do
      jobs =
        entries
        |> Enum.filter(&(&1.type == :file))
        |> Enum.map(fn entry ->
          file_path = Path.join(path, entry.name)
          {:ok, job} = ingest_file(file_path, mode, volume_name, role_id, shared_role_ids)
          job
        end)

      {:ok, jobs}
    end
  end

  # --- Access control ---

  @doc """
  Returns true if the given user can access a file at `relative_path`.
  - Super admins bypass all checks.
  - Files with no Document record are accessible to all (backward compat).
  - Files shared with the "public" role are accessible to all.
  - Otherwise: only the owning role (doc.role_id) or explicitly shared roles.
  """
  def can_access_file?(relative_path, current_user) do
    source = SourcePath.normalize_relative(relative_path)

    case Document.get_by_source(source) do
      nil ->
        true

      doc ->
        super_admin? = current_user.role.name == "super_admin"
        shared = doc.shared_role_ids
        public? = public_role_id() in shared

        super_admin? or
          public? or
          is_nil(doc.role_id) or
          doc.role_id == current_user.role_id or
          current_user.role_id in shared
    end
  end

  defp public_role_id do
    case Zaq.Accounts.get_role_by_name("public") do
      nil -> nil
      role -> role.id
    end
  end

  # --- Upload tracking ---

  def list_volumes, do: FileExplorer.list_volumes()

  def list_entries(volume_name, path), do: FileExplorer.list(volume_name, path)

  def create_directory(volume_name, path), do: FileExplorer.create_directory(volume_name, path)

  def rename_entry(volume_name, old_path, new_path),
    do: RenameService.rename_entry(volume_name, old_path, new_path)

  def upload_file(volume_name, path, content), do: FileExplorer.upload(volume_name, path, content)

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
  Records a newly uploaded file in the documents table with the uploader's role_id.
  This is called immediately at upload time — before any ingestion happens — so that
  the file browser can enforce role-based visibility right away.
  """
  def track_upload(volume_name, path, role_id) do
    source = SourcePath.build_source(volume_name, path)
    Document.upsert(%{source: source, role_id: role_id})
  end

  def delete_path(volume_name, path, type, volumes \\ nil) do
    DeleteService.delete_path(volume_name, path, type, volumes)
  end

  def delete_paths(volume_name, paths, volumes \\ nil) do
    DeleteService.delete_paths(volume_name, paths, volumes)
  end

  # --- Sharing ---

  def share_file(source, shared_role_ids) do
    doc =
      case Document.get_by_source(source) do
        nil -> elem(Document.create(%{source: source, shared_role_ids: shared_role_ids}), 1)
        doc -> elem(Document.set_shared_role_ids(doc, shared_role_ids), 1)
      end

    Chunk.update_shared_role_ids_for_document(doc.id, shared_role_ids)
    {:ok, shared_role_ids}
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

  defp create_job(path, mode, volume_name, role_id, shared_role_ids) do
    attrs =
      %{file_path: path, status: "pending", mode: to_string(mode)}
      |> then(fn a -> if volume_name, do: Map.put(a, :volume_name, volume_name), else: a end)
      |> then(fn a -> if role_id, do: Map.put(a, :role_id, role_id), else: a end)
      |> then(fn a ->
        if shared_role_ids != [], do: Map.put(a, :shared_role_ids, shared_role_ids), else: a
      end)

    %IngestJob{}
    |> IngestJob.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [j], j.status == ^status)
end
