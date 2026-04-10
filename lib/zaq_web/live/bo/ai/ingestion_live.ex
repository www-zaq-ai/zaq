# lib/zaq_web/live/bo/ai/ingestion_live.ex

defmodule ZaqWeb.Live.BO.AI.IngestionLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.IngestionComponents

  alias Zaq.Accounts.People
  alias Zaq.Ingestion
  alias Zaq.NodeRouter
  alias Zaq.System
  alias ZaqWeb.Live.BO.PreviewHelpers

  @allowed_extensions ~w(.md .txt .pdf .docx .xlsx .csv .png .jpg .jpeg)
  @ingestion_topic "ingestion:jobs"

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Zaq.PubSub, @ingestion_topic)

    volumes = fetch_volumes()
    current_volume = volumes |> Map.keys() |> List.first()

    {:ok,
     socket
     |> assign(
       current_path: "/bo/ingestion",
       current_dir: ".",
       breadcrumbs: [],
       entries: [],
       selected: MapSet.new(),
       jobs: [],
       status_filter: "all",
       ingest_mode: "async",
       # Volume state
       volumes: volumes,
       current_volume: current_volume,
       # Embedding readiness
       embedding_ready: System.embedding_ready?(),
       # Permission sharing
       share_modal_document_id: nil,
       share_modal_is_folder: false,
       share_modal_is_public: false,
       share_modal_original_is_public: false,
       share_modal_folder_path: nil,
       share_modal_permissions: [],
       share_modal_all_targets: build_share_targets_options(),
       share_modal_targets_options: build_share_targets_options(),
       share_modal_pending: [],
       # View mode
       view_mode: "list",
       # Modal state
       modal: nil,
       modal_path: nil,
       modal_name: "",
       modal_type: nil,
       modal_error: nil,
       # Move modal state
       move_folders: [],
       move_current_dir: ".",
       move_breadcrumbs: [],
       ingestion_map: %{},
       # Raw MD modal state
       raw_content: "",
       raw_filename: "",
       preview: nil
     )
     |> load_entries()
     |> load_jobs()
     |> allow_upload(:files,
       accept: @allowed_extensions,
       max_entries: 10,
       max_file_size: 20_000_000
     )}
  end

  # ────────────────────────────────────────────────────────────────
  # handle_event/3 — all clauses grouped together
  # ────────────────────────────────────────────────────────────────

  # Permission sharing (share modal)

  def handle_event("share_item", %{"path" => path, "type" => "directory"}, socket) do
    all_targets = socket.assigns.share_modal_all_targets

    permissions =
      ingestion_call(:list_folder_permissions, [socket.assigns.current_volume, path])

    is_public = Ingestion.folder_public?(socket.assigns.current_volume, path)

    {:noreply,
     assign(socket,
       modal: :share,
       modal_path: path,
       modal_name: Path.basename(path),
       modal_error: nil,
       share_modal_is_folder: true,
       share_modal_is_public: is_public,
       share_modal_original_is_public: is_public,
       share_modal_folder_path: path,
       share_modal_document_id: nil,
       share_modal_permissions: permissions,
       share_modal_pending: [],
       share_modal_targets_options: filtered_targets(all_targets, permissions, [])
     )}
  end

  def handle_event("share_item", %{"path" => path}, socket) do
    source = ingestion_call(:source_for, [socket.assigns.current_volume, path])
    doc = Ingestion.get_document_by_source!(source)
    permissions = ingestion_call(:list_document_permissions, [doc.id])

    all_targets = socket.assigns.share_modal_all_targets

    {:noreply,
     assign(socket,
       modal: :share,
       modal_path: path,
       modal_name: Path.basename(path),
       modal_error: nil,
       share_modal_is_folder: false,
       share_modal_is_public: "public" in doc.tags,
       share_modal_original_is_public: "public" in doc.tags,
       share_modal_folder_path: nil,
       share_modal_document_id: doc.id,
       share_modal_permissions: permissions,
       share_modal_pending: [],
       share_modal_targets_options: filtered_targets(all_targets, permissions, [])
     )}
  end

  def handle_event("toggle_public", _params, socket) do
    {:noreply, assign(socket, share_modal_is_public: not socket.assigns.share_modal_is_public)}
  end

  def handle_event("add_permission_target", %{"value" => value}, socket) do
    case parse_share_target(value, socket.assigns.share_modal_targets_options) do
      nil ->
        {:noreply, socket}

      new_entry ->
        pending = socket.assigns.share_modal_pending

        already_pending? =
          Enum.any?(pending, &(&1.type == new_entry.type and &1.id == new_entry.id))

        {:noreply,
         if already_pending? do
           socket
         else
           new_pending = pending ++ [new_entry]

           assign(socket,
             share_modal_pending: new_pending,
             share_modal_targets_options:
               filtered_targets(
                 socket.assigns.share_modal_all_targets,
                 socket.assigns.share_modal_permissions,
                 new_pending
               )
           )
         end}
    end
  end

  def handle_event("toggle_permission_right", %{"index" => idx_str, "right" => right}, socket) do
    idx = String.to_integer(idx_str)

    updated =
      socket.assigns.share_modal_pending
      |> List.update_at(idx, fn entry ->
        rights = entry.access_rights

        updated_rights =
          if right in rights, do: List.delete(rights, right), else: rights ++ [right]

        %{entry | access_rights: updated_rights}
      end)

    {:noreply, assign(socket, share_modal_pending: updated)}
  end

  def handle_event("remove_pending", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    updated = List.delete_at(socket.assigns.share_modal_pending, idx)

    {:noreply,
     assign(socket,
       share_modal_pending: updated,
       share_modal_targets_options:
         filtered_targets(
           socket.assigns.share_modal_all_targets,
           socket.assigns.share_modal_permissions,
           updated
         )
     )}
  end

  def handle_event("remove_permission", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    permissions =
      if socket.assigns.share_modal_is_folder do
        {:ok, _} =
          ingestion_call(:delete_folder_target_permission, [
            socket.assigns.current_volume,
            socket.assigns.share_modal_folder_path,
            id
          ])

        ingestion_call(:list_folder_permissions, [
          socket.assigns.current_volume,
          socket.assigns.share_modal_folder_path
        ])
      else
        {:ok, _} = ingestion_call(:delete_document_permission, [id])
        ingestion_call(:list_document_permissions, [socket.assigns.share_modal_document_id])
      end

    {:noreply,
     assign(socket,
       share_modal_permissions: permissions,
       share_modal_targets_options:
         filtered_targets(
           socket.assigns.share_modal_all_targets,
           permissions,
           socket.assigns.share_modal_pending
         )
     )}
  end

  def handle_event("confirm_share", _params, socket) do
    pending = socket.assigns.share_modal_pending
    name = socket.assigns.modal_name
    is_public = socket.assigns.share_modal_is_public
    original_is_public = socket.assigns.share_modal_original_is_public
    volume = socket.assigns.current_volume

    if socket.assigns.share_modal_is_folder do
      docs =
        ingestion_call(:list_documents_under_folder, [
          volume,
          socket.assigns.share_modal_folder_path
        ])

      for doc <- docs,
          %{type: type, id: id, access_rights: rights} <- pending do
        ingestion_call(:set_document_permission, [doc.id, type, id, rights])
      end

      maybe_update_folder_public(
        volume,
        socket.assigns.share_modal_folder_path,
        is_public,
        original_is_public
      )

      {:noreply,
       socket
       |> assign(modal: nil, modal_error: nil, share_modal_pending: [])
       |> load_entries()
       |> put_flash(:info, "Permissions applied to all documents in \"#{name}\".")}
    else
      doc_id = socket.assigns.share_modal_document_id

      for %{type: type, id: id, access_rights: rights} <- pending do
        ingestion_call(:set_document_permission, [doc_id, type, id, rights])
      end

      maybe_update_document_public(doc_id, is_public, original_is_public)

      permissions = ingestion_call(:list_document_permissions, [doc_id])

      {:noreply,
       socket
       |> assign(
         modal: nil,
         modal_error: nil,
         share_modal_permissions: permissions,
         share_modal_pending: []
       )
       |> load_entries()
       |> put_flash(:info, "Permissions saved for \"#{name}\".")}
    end
  end

  # Volume

  def handle_event("switch_volume", %{"volume" => volume}, socket) do
    {:noreply,
     socket
     |> assign(current_volume: volume, current_dir: ".", breadcrumbs: [], selected: MapSet.new())
     |> load_entries()}
  end

  # File Browser

  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(current_dir: path, selected: MapSet.new())
     |> assign_breadcrumbs(path)
     |> load_entries()}
  end

  def handle_event("go_back", _params, socket) do
    parent = parent_dir(socket.assigns.current_dir)

    {:noreply,
     socket
     |> assign(current_dir: parent, selected: MapSet.new())
     |> assign_breadcrumbs(parent)
     |> load_entries()}
  end

  def handle_event("toggle_select", %{"path" => path}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, path),
        do: MapSet.delete(socket.assigns.selected, path),
        else: MapSet.put(socket.assigns.selected, path)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("select_all", _params, socket) do
    all_paths =
      socket.assigns.entries
      |> Enum.map(fn e -> Path.join(socket.assigns.current_dir, e.name) end)
      |> MapSet.new()

    selected =
      if MapSet.equal?(socket.assigns.selected, all_paths),
        do: MapSet.new(),
        else: all_paths

    {:noreply, assign(socket, selected: selected)}
  end

  # View Mode

  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) when mode in ~w(list grid) do
    {:noreply, assign(socket, view_mode: mode)}
  end

  # Modal: New Folder

  def handle_event("show_new_folder_modal", _params, socket) do
    {:noreply, assign(socket, modal: :new_folder, modal_name: "", modal_error: nil)}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, modal_error: "Folder name cannot be empty.")}
    else
      path = Path.join(socket.assigns.current_dir, name)

      case ingestion_call(:create_directory, [socket.assigns.current_volume, path]) do
        :ok ->
          {:noreply,
           socket
           |> assign(modal: nil, modal_error: nil)
           |> load_entries()
           |> put_flash(:info, "Folder \"#{name}\" created.")}

        {:error, reason} ->
          {:noreply, assign(socket, modal_error: "Failed: #{inspect(reason)}")}
      end
    end
  end

  # Modal: Rename

  def handle_event("rename_item", %{"path" => path, "type" => type}, socket) do
    {:noreply,
     assign(socket,
       modal: :rename,
       modal_path: path,
       modal_name: Path.basename(path),
       modal_type: type,
       modal_error: nil
     )}
  end

  def handle_event("confirm_rename", %{"name" => new_name}, socket) do
    new_name = String.trim(new_name)
    old_path = socket.assigns.modal_path
    new_path = Path.join(Path.dirname(old_path), new_name)

    cond do
      new_name == "" ->
        {:noreply, assign(socket, modal_error: "Name cannot be empty.")}

      old_path == new_path ->
        {:noreply, assign(socket, modal: nil, modal_error: nil)}

      true ->
        do_rename(socket, old_path, new_path, new_name)
    end
  end

  # Modal: Delete single item

  def handle_event("delete_item", %{"path" => path, "type" => type}, socket) do
    {:noreply,
     assign(socket,
       modal: :delete,
       modal_path: path,
       modal_name: Path.basename(path),
       modal_type: type,
       modal_error: nil
     )}
  end

  def handle_event("confirm_delete", _params, socket) do
    result =
      ingestion_call(:delete_path, [
        socket.assigns.current_volume,
        socket.assigns.modal_path,
        socket.assigns.modal_type,
        socket.assigns.volumes
      ])

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(modal: nil, selected: MapSet.new(), modal_error: nil)
         |> load_entries()
         |> put_flash(:info, "\"#{socket.assigns.modal_name}\" deleted.")}

      {:error, reason} ->
        {:noreply, assign(socket, modal_error: "Delete failed: #{inspect(reason)}")}
    end
  end

  # Modal: Bulk delete

  def handle_event("show_delete_confirmation", _params, socket) do
    {:noreply, assign(socket, modal: :delete_selected, modal_error: nil)}
  end

  def handle_event("confirm_delete_selected", _params, socket) do
    volume = socket.assigns.current_volume

    results =
      ingestion_call(:delete_paths, [volume, socket.assigns.selected, socket.assigns.volumes])

    errors = Enum.filter(results, fn {_p, res} -> res != :ok end)

    socket =
      if errors == [] do
        socket
        |> assign(modal: nil, selected: MapSet.new(), modal_error: nil)
        |> load_entries()
        |> put_flash(:info, "#{MapSet.size(socket.assigns.selected)} item(s) deleted.")
      else
        socket
        |> assign(modal: nil, selected: MapSet.new(), modal_error: nil)
        |> load_entries()
        |> put_flash(:error, "Some items could not be deleted.")
      end

    {:noreply, socket}
  end

  # Modal: Move item

  def handle_event("move_item", %{"path" => path, "type" => type}, socket) do
    {:noreply,
     socket
     |> assign(
       modal: :move,
       modal_path: path,
       modal_name: Path.basename(path),
       modal_type: type,
       modal_error: nil,
       move_current_dir: ".",
       move_breadcrumbs: []
     )
     |> load_move_folders(".")}
  end

  def handle_event("move_navigate", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(move_current_dir: path)
     |> assign_move_breadcrumbs(path)
     |> load_move_folders(path)}
  end

  def handle_event("move_go_back", _params, socket) do
    parent = parent_dir(socket.assigns.move_current_dir)

    {:noreply,
     socket
     |> assign(move_current_dir: parent)
     |> assign_move_breadcrumbs(parent)
     |> load_move_folders(parent)}
  end

  def handle_event("confirm_move", _params, socket) do
    source = socket.assigns.modal_path
    dest_dir = socket.assigns.move_current_dir
    name = Path.basename(source)
    dest = Path.join(dest_dir, name)

    cond do
      Path.dirname(source) == dest_dir ->
        {:noreply, assign(socket, modal_error: "Already in this folder.")}

      String.starts_with?(dest_dir, source <> "/") ->
        {:noreply, assign(socket, modal_error: "Cannot move a folder into itself.")}

      true ->
        do_move(socket, source, dest, name, dest_dir)
    end
  end

  # Modal: Close

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal: nil, modal_error: nil)}
  end

  def handle_event("open_preview", %{"path" => path}, socket) do
    {:noreply, PreviewHelpers.open_preview(socket, path, :modal)}
  end

  def handle_event("close_preview_modal", _params, socket) do
    {:noreply, PreviewHelpers.close_preview(socket, :modal)}
  end

  # Modal: Add Raw MD

  def handle_event("show_add_raw_modal", _params, socket) do
    {:noreply,
     assign(socket,
       modal: :add_raw,
       raw_filename: "",
       raw_content: "",
       modal_error: nil
     )}
  end

  def handle_event("update_raw_field", %{"field" => "filename", "value" => value}, socket) do
    {:noreply, assign(socket, raw_filename: value)}
  end

  def handle_event("update_raw_field", %{"field" => "content", "value" => value}, socket) do
    {:noreply, assign(socket, raw_content: value)}
  end

  def handle_event("save_raw_content", %{"filename" => filename, "content" => content}, socket) do
    filename = String.trim(filename)
    content = String.trim(content)

    cond do
      filename == "" ->
        {:noreply, assign(socket, modal_error: "Filename cannot be empty.")}

      content == "" ->
        {:noreply, assign(socket, modal_error: "Content cannot be empty.")}

      true ->
        filename = ensure_md_extension(filename)
        dest = Path.join(socket.assigns.current_dir, filename)

        volume = socket.assigns.current_volume

        case ingestion_call(:upload_file, [volume, dest, content]) do
          {:ok, _} ->
            ingestion_call(:track_upload, [volume, dest])

            {:noreply,
             socket
             |> assign(modal: nil, modal_error: nil, raw_filename: "", raw_content: "")
             |> load_entries()
             |> load_jobs()
             |> put_flash(:info, "\"#{filename}\" saved.")}

          {:error, reason} ->
            {:noreply, assign(socket, modal_error: "Save failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("add_raw_content", params, socket) do
    handle_event("save_raw_content", params, socket)
  end

  # Ingestion

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, ingest_mode: mode)}
  end

  def handle_event("ingest_selected", _params, socket) do
    mode = String.to_existing_atom(socket.assigns.ingest_mode)
    volume = socket.assigns.current_volume

    for path <- socket.assigns.selected do
      case ingestion_call(:file_info, [volume, path]) do
        {:ok, %{type: :directory}} ->
          ingestion_call(:ingest_folder, [path, mode, volume])

        {:ok, %{type: :file}} ->
          ingestion_call(:ingest_file, [path, mode, volume])

        _ ->
          :skip
      end
    end

    {:noreply,
     socket
     |> assign(selected: MapSet.new())
     |> load_jobs()
     |> put_flash(:info, "Ingestion started.")}
  end

  def handle_event("retry_job", %{"id" => id}, socket) do
    case ingestion_call(:retry_job, [id]) do
      {:ok, _} -> {:noreply, socket |> load_jobs() |> put_flash(:info, "Job re-queued.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Retry failed: #{reason}")}
    end
  end

  def handle_event("cancel_job", %{"id" => id}, socket) do
    case ingestion_call(:cancel_job, [id]) do
      {:ok, _} -> {:noreply, socket |> load_jobs() |> put_flash(:info, "Job cancelled.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Cancel failed: #{reason}")}
    end
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(status_filter: status)
     |> load_jobs()}
  end

  # Upload

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("upload", _params, socket) do
    volume = socket.assigns.current_volume

    uploaded =
      consume_uploaded_entries(socket, :files, fn %{path: tmp_path}, entry ->
        binary = File.read!(tmp_path)
        dest = Path.join(socket.assigns.current_dir, entry.client_name)

        case ingestion_call(:upload_file, [volume, dest, binary]) do
          {:ok, _full_path} ->
            ingestion_call(:track_upload, [volume, dest])
            {:ok, dest}

          error ->
            error
        end
      end)

    {:noreply,
     socket
     |> load_entries()
     |> put_flash(:info, "#{length(uploaded)} file(s) uploaded.")}
  end

  # ────────────────────────────────────────────────────────────────
  # handle_info/2
  # ────────────────────────────────────────────────────────────────

  def handle_info({:job_updated, job}, socket) do
    socket =
      socket
      |> merge_job_update(job)
      |> maybe_refresh_entries_after_job(job)

    {:noreply, socket}
  end

  # ────────────────────────────────────────────────────────────────
  # Private helpers
  # ────────────────────────────────────────────────────────────────

  defp ensure_md_extension(filename) do
    if Path.extname(filename) == "", do: filename <> ".md", else: filename
  end

  defp parent_dir("."), do: "."

  defp parent_dir(path), do: Path.dirname(path)

  defp do_rename(socket, old_path, new_path, new_name) do
    volume = socket.assigns.current_volume

    case ingestion_call(:rename_entry, [volume, old_path, new_path]) do
      :ok ->
        {:noreply,
         socket
         |> assign(modal: nil, selected: MapSet.new(), modal_error: nil)
         |> load_entries()
         |> put_flash(:info, "Renamed to \"#{new_name}\".")}

      {:error, reason} ->
        {:noreply, assign(socket, modal_error: "Rename failed: #{inspect(reason)}")}
    end
  end

  defp do_move(socket, source, dest, name, dest_dir) do
    volume = socket.assigns.current_volume

    case ingestion_call(:rename_entry, [volume, source, dest]) do
      :ok ->
        {:noreply,
         socket
         |> assign(modal: nil, selected: MapSet.new(), modal_error: nil)
         |> load_entries()
         |> put_flash(
           :info,
           "Moved \"#{name}\" to #{if dest_dir == ".", do: "root", else: dest_dir}."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, modal_error: "Move failed: #{inspect(reason)}")}
    end
  end

  defp load_entries(socket) do
    volume = socket.assigns.current_volume

    case ingestion_call(:directory_snapshot, [
           volume,
           socket.assigns.current_dir,
           socket.assigns.current_user
         ]) do
      {:ok, snapshot} ->
        socket
        |> assign(entries: snapshot.entries)
        |> assign(ingestion_map: snapshot.ingestion_map)

      {:error, _} ->
        socket
        |> assign(entries: [])
        |> assign(ingestion_map: %{})
    end
  end

  defp load_jobs(socket) do
    opts =
      case socket.assigns.status_filter do
        "all" -> []
        "others" -> [status: ["pending", "processing", "completed_with_errors"]]
        status -> [status: status]
      end

    jobs =
      case ingestion_call(:list_jobs, [opts]) do
        list when is_list(list) -> list
        _ -> []
      end

    assign(socket, jobs: jobs)
  end

  defp merge_job_update(socket, %{id: id} = job) do
    jobs = socket.assigns.jobs
    existing_index = Enum.find_index(jobs, &(&1.id == id))

    cond do
      not status_match?(socket.assigns.status_filter, job.status) ->
        handle_filtered_job(socket, jobs, existing_index)

      is_integer(existing_index) ->
        update_existing_job(socket, jobs, existing_index, job)

      true ->
        add_new_job(socket, jobs, job)
    end
  end

  defp merge_job_update(socket, _), do: socket

  defp maybe_update_folder_public(_volume, _path, same, same), do: :ok

  defp maybe_update_folder_public(volume, path, true, _),
    do: Ingestion.set_folder_public(volume, path)

  defp maybe_update_folder_public(volume, path, false, _),
    do: Ingestion.unset_folder_public(volume, path)

  defp maybe_update_document_public(_doc_id, same, same), do: :ok

  defp maybe_update_document_public(doc_id, true, _),
    do: Ingestion.add_document_tag(doc_id, "public")

  defp maybe_update_document_public(doc_id, false, _),
    do: Ingestion.remove_document_tag(doc_id, "public")

  defp status_match?("all", _job_status), do: true

  defp status_match?("others", job_status),
    do: job_status in ["pending", "processing", "completed_with_errors"]

  defp status_match?(status_filter, job_status), do: status_filter == job_status

  defp handle_filtered_job(socket, jobs, existing_index) when is_integer(existing_index) do
    assign(socket, jobs: List.delete_at(jobs, existing_index))
  end

  defp handle_filtered_job(socket, _jobs, _existing_index), do: socket

  defp update_existing_job(socket, jobs, existing_index, job) do
    updated_jobs =
      jobs
      |> List.replace_at(existing_index, job)
      |> sort_jobs_desc()

    assign(socket, jobs: updated_jobs)
  end

  defp add_new_job(socket, jobs, job) do
    updated_jobs =
      [job | jobs]
      |> sort_jobs_desc()
      |> Enum.take(20)

    assign(socket, jobs: updated_jobs)
  end

  defp sort_jobs_desc(jobs), do: Enum.sort_by(jobs, & &1.inserted_at, {:desc, DateTime})

  defp maybe_refresh_entries_after_job(socket, %{status: status})
       when status in ["completed", "completed_with_errors", "failed"] do
    load_entries(socket)
  end

  # Refresh as soon as chunks are scheduled (prepare_file_chunks just completed):
  # the sidecar .md is on disk and in the DB at this point, before any embedding runs.
  defp maybe_refresh_entries_after_job(socket, %{
         status: "processing",
         total_chunks: total,
         ingested_chunks: 0
       })
       when is_integer(total) and total > 0 do
    load_entries(socket)
  end

  defp maybe_refresh_entries_after_job(socket, _job), do: socket

  defp fetch_volumes do
    case ingestion_call(:list_volumes, []) do
      volumes when is_map(volumes) and map_size(volumes) > 0 -> volumes
      _ -> %{"default" => "priv/documents"}
    end
  end

  defp ingestion_call(fun, args) do
    NodeRouter.call(:ingestion, Ingestion, fun, args)
  end

  defp assign_breadcrumbs(socket, "."), do: assign(socket, breadcrumbs: [])

  defp assign_breadcrumbs(socket, path) do
    parts = Path.split(path)

    crumbs =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {name, idx} ->
        %{name: name, path: parts |> Enum.take(idx + 1) |> Path.join()}
      end)

    assign(socket, breadcrumbs: crumbs)
  end

  defp load_move_folders(socket, dir) do
    volume = socket.assigns.current_volume
    moving_path = socket.assigns.modal_path

    case ingestion_call(:list_entries, [volume, dir]) do
      {:ok, entries} ->
        folders =
          entries
          |> Enum.filter(fn e ->
            e.type == :directory and Path.join(dir, e.name) != moving_path
          end)
          |> Enum.sort_by(& &1.name)

        assign(socket, move_folders: folders)

      {:error, _} ->
        assign(socket, move_folders: [])
    end
  end

  defp assign_move_breadcrumbs(socket, "."), do: assign(socket, move_breadcrumbs: [])

  defp assign_move_breadcrumbs(socket, path) do
    parts = Path.split(path)

    crumbs =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {name, idx} ->
        %{name: name, path: parts |> Enum.take(idx + 1) |> Path.join()}
      end)

    assign(socket, move_breadcrumbs: crumbs)
  end

  # Kept public for backward-compat with tests that call these directly.
  defdelegate format_size(bytes), to: ZaqWeb.Live.BO.AI.IngestionComponents
  defdelegate status_color(status), to: ZaqWeb.Live.BO.AI.IngestionComponents

  defp build_share_targets_options do
    people_opts =
      People.list_people()
      |> Enum.map(fn p -> {"#{p.full_name} (#{p.email})", "person:#{p.id}"} end)

    teams_opts =
      People.list_teams()
      |> Enum.map(fn t -> {"team: #{t.name}", "team:#{t.id}"} end)

    people_opts ++ teams_opts
  end

  defp filtered_targets(all_targets, permissions, pending) do
    excluded =
      Enum.map(permissions, fn p ->
        if p.person, do: "person:#{p.person.id}", else: "team:#{p.team.id}"
      end) ++ Enum.map(pending, fn e -> "#{e.type}:#{e.id}" end)

    Enum.reject(all_targets, fn {_label, value} -> value in excluded end)
  end

  defp parse_share_target(value, options) do
    with [type_str, id_str] <- String.split(value, ":", parts: 2),
         type when type in [:person, :team] <- String.to_existing_atom(type_str),
         {id, ""} <- Integer.parse(id_str),
         {label, _} <- Enum.find(options, fn {_l, v} -> v == value end) do
      %{type: type, id: id, name: label, access_rights: ["read"]}
    else
      _ -> nil
    end
  end

  @doc """
  Returns the BO URL for viewing a file in the browser.
  Path segments are joined and appended to /bo/files/.
  Example: file_url("docs/guide.md") => "/bo/files/docs/guide.md"
  """
  def file_url(relative_path) do
    # Normalise: strip leading "./" so the URL is clean
    clean =
      relative_path
      |> Path.split()
      |> Enum.reject(&(&1 == "."))
      |> Enum.join("/")

    "/bo/files/#{clean}"
  end
end
