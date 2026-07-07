# lib/zaq_web/live/bo/ai/ingestion_live.ex

defmodule ZaqWeb.Live.BO.AI.IngestionLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.IngestionComponents
  import ZaqWeb.Components.DesignSystem.IngestionFileStatus, only: [record_path: 1]

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, ExternalSource, FileExplorer}
  alias Zaq.NodeRouter
  alias Zaq.System
  alias ZaqWeb.Live.BO.PreviewHelpers

  @allowed_extensions ~w(.md .txt .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg)
  @ingestion_topic "ingestion:jobs"

  # A "Preparing…" entry normally clears via a terminal job broadcast. If a job
  # is orphaned (hard VM/node kill emits no Oban telemetry), that broadcast may
  # never arrive and the bar would linger until Oban's orphan rescue. As a
  # belt-and-suspenders bound, prune prep entries that have not received a fresh
  # progress update within the Python runner's own timeout — matching
  # `Zaq.Ingestion.Python.Runner` (30 min). Overridable in tests via
  # `:ingestion_prep_ttl_ms`.
  @prep_ttl_ms_default :timer.minutes(30)
  @prep_prune_interval_ms :timer.minutes(1)

  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Zaq.PubSub, @ingestion_topic)

    provider = normalize_provider(Map.get(params, "provider"))
    volumes = fetch_volumes()
    current_volume = volumes |> Map.keys() |> List.first()

    {:ok,
     socket
     |> assign(
       current_path: ingestion_path(provider),
       provider: provider,
       provider_config_id: provider_config_id(provider),
       provider_folder_stack: [],
       provider_page: nil,
       provider_page_token: nil,
       provider_error: nil,
       current_dir: ".",
       breadcrumbs: [],
       entries: [],
       selected: MapSet.new(),
       records_by_path: %{},
       jobs: [],
       # Set of job ids currently in their preparation phase, derived from the
       # jobs list on every change so the high-frequency :job_progress handler
       # can gate on an O(1) lookup instead of scanning the full jobs list.
       active_prep_ids: MapSet.new(),
       # Transient PDF-prep progress, keyed by job id (not persisted)
       prep_progress: %{},
       # Monotonic ms of the last progress update per prep entry, used to expire
       # stale bars left behind by an orphaned (never-finalized) job.
       prep_seen_at: %{},
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
       share_modal_read_only: false,
       share_modal_notice: nil,
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
       preview: nil,
       # Folder drop
       folder_drop_skipped: []
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
       share_modal_targets_options: filtered_targets(all_targets, permissions, []),
       share_modal_read_only: false,
       share_modal_notice: nil
     )}
  end

  def handle_event("view_provider_permissions", %{"path" => path}, socket) do
    record = Map.get(socket.assigns.records_by_path, path)

    with %{} <- record,
         record <- with_provider_attrs(record, socket),
         %Document{} = doc <- Document.get_by_source(ExternalSource.source(record)) do
      permissions = ingestion_call(:list_document_permissions, [doc.id])

      {:noreply,
       assign(socket,
         modal: :share,
         modal_path: path,
         modal_name: record.name || path,
         modal_error: nil,
         share_modal_is_folder: false,
         share_modal_is_public: "public" in doc.tags,
         share_modal_original_is_public: "public" in doc.tags,
         share_modal_folder_path: nil,
         share_modal_document_id: doc.id,
         share_modal_permissions: permissions,
         share_modal_pending: [],
         share_modal_targets_options: [],
         share_modal_read_only: true,
         share_modal_notice:
           "Permissions are imported from #{provider_label(socket.assigns.provider)} and must be managed in the data source. Refresh ingestion to update this list."
       )}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "No imported permissions are available yet. Ingest this provider record to review ZAQ access."
         )}
    end
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
       share_modal_targets_options: filtered_targets(all_targets, permissions, []),
       share_modal_read_only: false,
       share_modal_notice: nil
     )}
  end

  def handle_event("toggle_public", _params, %{assigns: %{share_modal_read_only: true}} = socket),
    do: {:noreply, socket}

  def handle_event("toggle_public", _params, socket) do
    {:noreply, assign(socket, share_modal_is_public: not socket.assigns.share_modal_is_public)}
  end

  def handle_event(
        "add_permission_target",
        _params,
        %{assigns: %{share_modal_read_only: true}} = socket
      ),
      do: {:noreply, socket}

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

  def handle_event(
        "toggle_permission_right",
        _params,
        %{assigns: %{share_modal_read_only: true}} = socket
      ),
      do: {:noreply, socket}

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

  def handle_event(
        "remove_pending",
        _params,
        %{assigns: %{share_modal_read_only: true}} = socket
      ),
      do: {:noreply, socket}

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

  def handle_event(
        "remove_permission",
        _params,
        %{assigns: %{share_modal_read_only: true}} = socket
      ),
      do: {:noreply, socket}

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

  def handle_event("confirm_share", _params, %{assigns: %{share_modal_read_only: true}} = socket),
    do: {:noreply, socket}

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
    if provider_mode?(socket) do
      {:noreply, navigate_provider(socket, path)}
    else
      {:noreply,
       socket
       |> assign(current_dir: path, selected: MapSet.new())
       |> assign_breadcrumbs(path)
       |> load_entries()}
    end
  end

  def handle_event("go_back", _params, socket) do
    if provider_mode?(socket) do
      {:noreply, provider_go_back(socket)}
    else
      parent = parent_dir(socket.assigns.current_dir)

      {:noreply,
       socket
       |> assign(current_dir: parent, selected: MapSet.new())
       |> assign_breadcrumbs(parent)
       |> load_entries()}
    end
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
      |> Enum.map(&record_path/1)
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

  def handle_event("show_new_folder_modal", _params, %{assigns: %{provider: provider}} = socket)
      when provider not in ["local", "zaq_local"] do
    {:noreply, put_flash(socket, :info, "Provider folders are read-only in this phase.")}
  end

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

  def handle_event("rename_item", %{"path" => _path}, %{assigns: %{provider: provider}} = socket)
      when provider not in ["local", "zaq_local"] do
    {:noreply, put_flash(socket, :info, "Provider records are read-only in this phase.")}
  end

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

  def handle_event("delete_item", %{"path" => _path}, %{assigns: %{provider: provider}} = socket)
      when provider not in ["local", "zaq_local"] do
    {:noreply, put_flash(socket, :info, "Provider records are read-only in this phase.")}
  end

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

  def handle_event(
        "show_delete_confirmation",
        _params,
        %{assigns: %{provider: provider}} = socket
      )
      when provider not in ["local", "zaq_local"] do
    {:noreply, put_flash(socket, :info, "Provider records are read-only in this phase.")}
  end

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

  def handle_event("move_item", %{"path" => _path}, %{assigns: %{provider: provider}} = socket)
      when provider not in ["local", "zaq_local"] do
    {:noreply, put_flash(socket, :info, "Provider records are read-only in this phase.")}
  end

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

  def handle_event("open_preview", %{"path" => path, "filename" => filename}, socket) do
    cond do
      provider_mode?(socket) and Map.has_key?(socket.assigns.records_by_path, path) ->
        {:noreply, open_provider_preview(socket, path)}

      provider_mode?(socket) and external_sidecar_preview?(path) ->
        {:noreply, open_local_preview(socket, path, filename)}

      provider_mode?(socket) ->
        {:noreply, put_flash(socket, :error, "Preview is unavailable for this provider record.")}

      true ->
        {:noreply, open_local_preview(socket, path, filename)}
    end
  end

  def handle_event("open_preview", %{"path" => path}, socket) do
    cond do
      provider_mode?(socket) and Map.has_key?(socket.assigns.records_by_path, path) ->
        {:noreply, open_provider_preview(socket, path)}

      provider_mode?(socket) and external_sidecar_preview?(path) ->
        {:noreply, PreviewHelpers.open_preview(socket, path, :modal)}

      provider_mode?(socket) ->
        {:noreply, put_flash(socket, :error, "Preview is unavailable for this provider record.")}

      true ->
        {:noreply, PreviewHelpers.open_preview(socket, path, :modal)}
    end
  end

  def handle_event("provider_permissions_info", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       "Permissions are managed in the data source. Update sharing there, then refresh ingestion to import the latest permissions."
     )}
  end

  def handle_event("close_preview_modal", _params, socket) do
    {:noreply, PreviewHelpers.close_preview(socket, :modal)}
  end

  # Modal: Add Raw MD

  def handle_event("show_add_raw_modal", _params, socket) do
    if provider_mode?(socket) do
      {:noreply, put_flash(socket, :info, "Provider records are read-only in this phase.")}
    else
      {:noreply,
       assign(socket,
         modal: :add_raw,
         raw_filename: "",
         raw_content: "",
         modal_error: nil
       )}
    end
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

        case ingestion_call(:save_file, [volume, dest, content]) do
          {:ok, actual_dest} ->
            ingestion_call(:track_upload, [volume, actual_dest])

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
    records = selected_records(socket)
    result = dispatch_ingest_records(records, %{mode: socket.assigns.ingest_mode})

    socket =
      socket
      |> assign(selected: MapSet.new())
      |> load_jobs()
      |> put_ingest_result_flash(result)

    {:noreply, socket}
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

  # Folder drop

  # Payload: %{"skipped" => [%{"name" => string, "path" => string, "reason" => string}]}
  def handle_event("folder_drop_skipped", %{"skipped" => skipped}, socket)
      when is_list(skipped) do
    {:noreply, assign(socket, folder_drop_skipped: skipped)}
  end

  def handle_event("folder_drop_skipped", _bad_payload, socket) do
    {:noreply, socket}
  end

  # Upload

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("upload", _params, socket) do
    socket = assign(socket, folder_drop_skipped: [])
    all_done? = Enum.all?(socket.assigns.uploads.files.entries, &(&1.progress == 100))

    if all_done? do
      volume = socket.assigns.current_volume
      current_dir = socket.assigns.current_dir

      uploaded =
        consume_uploaded_entries(socket, :files, fn %{path: tmp_path}, entry ->
          upload_entry(volume, current_dir, tmp_path, entry)
        end)

      {:noreply,
       socket
       |> load_entries()
       |> put_flash(:info, "#{length(uploaded)} file(s) uploaded.")
       |> push_event("folder_batch_done", %{})}
    else
      {:noreply, socket}
    end
  end

  defp upload_entry(volume, current_dir, tmp_path, entry) do
    relative =
      case entry.client_relative_path do
        path when is_binary(path) and path != "" -> path
        _ -> entry.client_name
      end

    dest = Path.join(current_dir, relative)
    binary = File.read!(tmp_path)

    case ingestion_call(:upload_file, [volume, dest, binary]) do
      {:ok, actual_dest} ->
        ingestion_call(:track_upload, [volume, actual_dest])
        {:ok, actual_dest}

      error ->
        error
    end
  end

  # ────────────────────────────────────────────────────────────────
  # handle_info/2
  # ────────────────────────────────────────────────────────────────

  def handle_info({:job_updated, job}, socket) do
    socket =
      socket
      |> merge_job_update(job)
      |> clear_prep_progress_when_done(job)
      |> maybe_refresh_entries_after_job(job)

    {:noreply, socket}
  end

  def handle_info({:job_progress, job_id, payload}, socket) when is_map(payload) do
    # Only record progress for a job the client still sees in its preparation
    # phase. This drops stragglers that arrive after the job moved on (PubSub
    # ordering is not guaranteed), which would otherwise re-show a bar on an
    # already-finished or chunk-scheduled job.
    if active_prep_job?(socket, job_id) do
      {:noreply, record_prep_progress(socket, job_id, payload)}
    else
      {:noreply, socket}
    end
  end

  # Periodic sweep: drop prep entries with no progress update within the TTL.
  # Self-reschedules only while entries remain, so an idle panel stops ticking.
  def handle_info(:prune_prep_progress, socket) do
    now = :erlang.monotonic_time(:millisecond)
    ttl = prep_ttl_ms()

    stale =
      for {id, seen_at} <- socket.assigns.prep_seen_at, now - seen_at >= ttl, do: id

    socket = Enum.reduce(stale, socket, fn id, acc -> drop_prep_progress(acc, id) end)

    if socket.assigns.prep_progress != %{}, do: schedule_prep_prune()

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
    if provider_mode?(socket), do: load_provider_entries(socket), else: load_local_entries(socket)
  end

  defp load_local_entries(socket) do
    volume = socket.assigns.current_volume

    case ingestion_call(:directory_snapshot, [
           volume,
           socket.assigns.current_dir,
           socket.assigns.current_user
         ]) do
      {:ok, snapshot} ->
        socket
        |> assign(entries: snapshot.entries)
        |> assign(records_by_path: records_by_path(snapshot.entries))
        |> assign(ingestion_map: snapshot.ingestion_map)

      {:error, _} ->
        socket
        |> assign(entries: [])
        |> assign(records_by_path: %{})
        |> assign(ingestion_map: %{})
    end
  end

  defp load_provider_entries(%{assigns: %{provider_config_id: nil}} = socket) do
    assign(socket,
      entries: [],
      records_by_path: %{},
      ingestion_map: %{},
      provider_error: "No enabled data-source configuration found for #{socket.assigns.provider}."
    )
  end

  defp load_provider_entries(socket) do
    case dispatch_list_files(socket.assigns.provider, provider_list_params(socket)) do
      {:ok, %Zaq.Contracts.RecordPage{} = page} ->
        records = Enum.map(page.records || [], &with_provider_attrs(&1, socket))
        {records, ingestion_map} = enrich_provider_records(records)

        socket
        |> assign(entries: records)
        |> assign(records_by_path: records_by_path(records))
        |> assign(ingestion_map: ingestion_map)
        |> assign(provider_page: page)
        |> assign(provider_page_token: get_in(page.pagination, [:cursor]))
        |> assign(provider_error: nil)

      {:error, reason} ->
        socket
        |> assign(entries: [], records_by_path: %{}, ingestion_map: %{})
        |> assign(provider_error: "Failed to load provider records: #{inspect(reason)}")

      _ ->
        socket
        |> assign(entries: [], records_by_path: %{}, ingestion_map: %{})
        |> assign(provider_error: "Failed to load provider records.")
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

    assign_jobs(socket, jobs)
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

  # Once chunk scheduling starts (or the job ends), the prep phase is over —
  # drop the transient progress entry so the UI falls back to chunk progress.
  defp clear_prep_progress_when_done(socket, %{id: id, status: "processing", total_chunks: total})
       when is_integer(total) and total > 0 do
    drop_prep_progress(socket, id)
  end

  defp clear_prep_progress_when_done(socket, %{id: id, status: status})
       when status in ["completed", "completed_with_errors", "failed", "cancelled"] do
    drop_prep_progress(socket, id)
  end

  # A retry sends the job back to "pending" during Oban backoff. No fresh
  # progress arrives until the next attempt re-enters "processing", so drop the
  # stale entry now instead of leaving a frozen bar through the backoff window.
  defp clear_prep_progress_when_done(socket, %{id: id, status: "pending"}) do
    drop_prep_progress(socket, id)
  end

  defp clear_prep_progress_when_done(socket, _job), do: socket

  # True when the client still holds this job in its preparation phase. The set
  # is kept in sync with the jobs list (see assign_jobs/2), so this is an O(1)
  # membership test even when :job_progress fires per-image at high frequency.
  defp active_prep_job?(socket, job_id) do
    MapSet.member?(socket.assigns.active_prep_ids, job_id)
  end

  # Assigns the jobs list and recomputes the active-prep id set in one place, so
  # every jobs mutation keeps active_prep_ids consistent. A job is in its prep
  # phase when it is "processing", has no chunks scheduled yet, and is not yet
  # finished (the completed_at guard rejects a stale/duplicate entry).
  defp assign_jobs(socket, jobs) do
    active_prep_ids =
      for job <- jobs,
          job.status == "processing" and job.total_chunks == 0 and is_nil(job.completed_at),
          into: MapSet.new(),
          do: job.id

    assign(socket, jobs: jobs, active_prep_ids: active_prep_ids)
  end

  # Records a fresh progress payload and its timestamp, starting the prune
  # sweep when this is the first live entry (so the timer only runs while there
  # is something to expire).
  defp record_prep_progress(socket, job_id, payload) do
    was_empty = socket.assigns.prep_progress == %{}

    socket =
      assign(socket,
        prep_progress: Map.put(socket.assigns.prep_progress, job_id, payload),
        prep_seen_at:
          Map.put(socket.assigns.prep_seen_at, job_id, :erlang.monotonic_time(:millisecond))
      )

    if was_empty, do: schedule_prep_prune()

    socket
  end

  defp drop_prep_progress(socket, id) do
    assign(socket,
      prep_progress: Map.delete(socket.assigns.prep_progress, id),
      prep_seen_at: Map.delete(socket.assigns.prep_seen_at, id)
    )
  end

  defp schedule_prep_prune do
    Process.send_after(self(), :prune_prep_progress, @prep_prune_interval_ms)
  end

  defp prep_ttl_ms do
    Application.get_env(:zaq, :ingestion_prep_ttl_ms, @prep_ttl_ms_default)
  end

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
    assign_jobs(socket, List.delete_at(jobs, existing_index))
  end

  defp handle_filtered_job(socket, _jobs, _existing_index), do: socket

  defp update_existing_job(socket, jobs, existing_index, job) do
    updated_jobs =
      jobs
      |> List.replace_at(existing_index, job)
      |> sort_jobs_desc()

    assign_jobs(socket, updated_jobs)
  end

  defp add_new_job(socket, jobs, job) do
    updated_jobs =
      [job | jobs]
      |> sort_jobs_desc()
      |> Enum.take(20)

    assign_jobs(socket, updated_jobs)
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
    NodeRouter.invoke(:ingestion, Ingestion, fun, args)
  end

  defp dispatch_list_files(provider, params) do
    opts = [action: :data_source_list_files]
    opts = Keyword.put(opts, :data_source_bridge_module, data_source_bridge_module())

    Event.new(%{provider: provider, params: params}, :channels, opts: opts)
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp data_source_bridge_module do
    Application.get_env(:zaq, :ingestion_data_source_bridge_module, DataSourceBridge)
  end

  defp dispatch_ingest_records([], _params), do: {:ok, []}

  defp dispatch_ingest_records(records, params) do
    # Phase 1 sends canonical records to ingestion. Future external data-source
    # records should follow this same path so BO never branches on source origin.
    event =
      Event.new(%{records: records, params: params}, :ingestion, opts: [action: :ingest_records])

    NodeRouter.dispatch(event).response
  end

  defp selected_records(socket) do
    socket.assigns.selected
    |> Enum.map(&Map.get(socket.assigns.records_by_path, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&with_provider_attrs(&1, socket))
  end

  defp records_by_path(entries), do: Map.new(entries, &{record_path(&1), &1})

  defp enrich_provider_records(records) do
    documents_by_source = provider_documents_by_source(records)

    Enum.map_reduce(records, %{}, fn record, acc ->
      source = ExternalSource.source(record)
      sidecar_source = ExternalSource.sidecar_source(record)
      doc = Map.get(documents_by_source, source)
      sidecar_doc = Map.get(documents_by_source, sidecar_source)

      record = maybe_attach_sidecar_record(record, sidecar_doc)
      status = provider_record_status(record, doc)

      {record, Map.put(acc, record.name, status)}
    end)
  end

  defp provider_documents_by_source(records) do
    records
    |> Enum.flat_map(fn record ->
      [ExternalSource.source(record), ExternalSource.sidecar_source(record)]
    end)
    |> Document.list_by_sources()
    |> Map.new(&{&1.source, &1})
  end

  defp maybe_attach_sidecar_record(record, nil), do: record

  defp maybe_attach_sidecar_record(record, sidecar_doc) do
    attrs = Map.get(record, :attributes, %{})

    related = %{
      "name" => sidecar_display_name(record, sidecar_doc),
      "path" => sidecar_relative_path(record, sidecar_doc),
      "preview_path" => sidecar_preview_path(record, sidecar_doc),
      "size" => byte_size(sidecar_doc.content || "")
    }

    %{record | attributes: Map.put(attrs, "related_record", related)}
  end

  defp sidecar_display_name(record, sidecar_doc) do
    case record.name do
      name when is_binary(name) and name != "" -> Path.rootname(name) <> ".md"
      _ -> Path.basename(sidecar_doc.metadata["sidecar_file_path"] || sidecar_doc.source)
    end
  end

  defp sidecar_preview_path(record, sidecar_doc) do
    sidecar_file_path = sidecar_doc.metadata["sidecar_file_path"]

    cond do
      is_binary(sidecar_file_path) and sidecar_file_path != "" ->
        external_sidecar_preview_path(sidecar_file_path)

      ExternalSource.external?(record) ->
        record
        |> ExternalSource.sidecar_relative_path(".md")
        |> external_sidecar_preview_path()

      true ->
        sidecar_file_path
    end
  end

  defp sidecar_relative_path(record, sidecar_doc) do
    sidecar_file_path = sidecar_doc.metadata["sidecar_file_path"]

    cond do
      is_binary(sidecar_file_path) and sidecar_file_path != "" -> sidecar_file_path
      ExternalSource.external?(record) -> ExternalSource.sidecar_relative_path(record, ".md")
      true -> sidecar_file_path
    end
  end

  defp external_sidecar_preview_path(relative_path) do
    volumes = FileExplorer.list_volumes()
    base_path = Path.expand(FileExplorer.base_path())

    existing_volume =
      Enum.find(volumes, fn {_name, path} -> File.exists?(Path.join(path, relative_path)) end)

    base_volume = Enum.find(volumes, fn {_name, path} -> Path.expand(path) == base_path end)

    case existing_volume || base_volume do
      {volume, _path} -> Path.join(volume, relative_path)
      nil -> relative_path
    end
  end

  defp external_sidecar_preview?(path) when is_binary(path) do
    path |> Path.split() |> Enum.member?(".external-sidecars")
  end

  defp external_sidecar_preview?(_path), do: false

  defp open_local_preview(socket, path, filename) do
    socket = PreviewHelpers.open_preview(socket, path, :modal)

    case socket.assigns.preview do
      %{filename: _} = preview when is_binary(filename) and filename != "" ->
        assign(socket, preview: %{preview | filename: filename})

      _ ->
        socket
    end
  end

  defp provider_record_status(%{kind: kind}, _doc) when kind in [:folder, "folder"] do
    %{type: :directory, total_size: 0, file_count: 0, ingested_count: 0, is_public: false}
  end

  defp provider_record_status(_record, nil) do
    %{ingested_at: nil, stale?: false, permissions_count: 0, is_public: false, can_share?: false}
  end

  defp provider_record_status(record, doc) do
    stale? =
      record.modified_at && doc.updated_at &&
        DateTime.compare(record.modified_at, doc.updated_at) == :gt

    %{
      ingested_at: doc.updated_at,
      stale?: stale? || false,
      permissions_count: length(Ingestion.list_document_permissions(doc.id)),
      is_public: "public" in doc.tags,
      can_share?: false
    }
  end

  defp with_provider_attrs(record, %{assigns: %{provider: "local"}}), do: record

  defp with_provider_attrs(record, socket) do
    attrs =
      record
      |> Map.get(:attributes, %{})
      |> Map.put("provider", socket.assigns.provider)
      |> Map.put("config_id", socket.assigns.provider_config_id)
      |> Map.put("provider_record_id", record.id)
      |> Map.put("provider_url", record.url)
      |> Map.put("provider_mime_type", record.mime_type)

    %{record | attributes: attrs}
  end

  defp normalize_provider(nil), do: "local"
  defp normalize_provider(""), do: "local"
  defp normalize_provider("local"), do: "local"
  defp normalize_provider("zaq_local"), do: "local"
  defp normalize_provider(provider) when is_binary(provider), do: provider

  defp provider_label(provider) when is_binary(provider) do
    provider
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp provider_label(_provider), do: "the data source"

  defp ingestion_path("local"), do: "/bo/ingestion"
  defp ingestion_path(provider), do: "/bo/ingestion/#{provider}"

  defp provider_mode?(socket), do: socket.assigns.provider != "local"

  defp provider_config_id("local"), do: nil

  defp provider_config_id(provider) do
    case ChannelConfig.get_by_provider(provider) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp provider_list_params(socket) do
    folder = List.last(socket.assigns.provider_folder_stack)

    filters =
      case folder do
        %{id: id} when is_binary(id) and id != "." -> %{"parent" => id, "include_shared" => false}
        _ -> %{}
      end

    %{
      "config_id" => socket.assigns.provider_config_id,
      "filters" => filters,
      "include_permissions" => true
    }
  end

  defp navigate_provider(socket, ".") do
    socket
    |> assign(
      provider_folder_stack: [],
      current_dir: ".",
      breadcrumbs: [],
      selected: MapSet.new()
    )
    |> load_entries()
  end

  defp navigate_provider(socket, id) do
    cond do
      crumb_index = Enum.find_index(socket.assigns.provider_folder_stack, &(&1.id == id)) ->
        stack = Enum.take(socket.assigns.provider_folder_stack, crumb_index + 1)

        socket
        |> assign(provider_folder_stack: stack, current_dir: id, selected: MapSet.new())
        |> assign_provider_breadcrumbs(stack)
        |> load_entries()

      record = Map.get(socket.assigns.records_by_path, id) ->
        stack =
          socket.assigns.provider_folder_stack ++ [%{id: record_path(record), name: record.name}]

        socket
        |> assign(
          provider_folder_stack: stack,
          current_dir: record_path(record),
          selected: MapSet.new()
        )
        |> assign_provider_breadcrumbs(stack)
        |> load_entries()

      true ->
        socket
    end
  end

  defp provider_go_back(socket) do
    stack = Enum.drop(socket.assigns.provider_folder_stack, -1)

    current_dir =
      case List.last(stack) do
        %{id: id} -> id
        _ -> "."
      end

    socket
    |> assign(provider_folder_stack: stack, current_dir: current_dir, selected: MapSet.new())
    |> assign_provider_breadcrumbs(stack)
    |> load_entries()
  end

  defp assign_provider_breadcrumbs(socket, stack) do
    crumbs = Enum.map(stack, &%{name: &1.name, path: &1.id})
    assign(socket, breadcrumbs: crumbs)
  end

  defp open_provider_preview(socket, id) do
    record = Map.get(socket.assigns.records_by_path, id)
    url = record && Map.get(record, :url)

    if is_binary(url) and url != "" do
      preview = %{
        relative_path: url,
        filename: record.name || id,
        ext: record.name |> to_string() |> Path.extname() |> String.downcase(),
        kind: :external_url,
        content: nil,
        rendered_html: nil,
        file_size: record.size,
        modified_at: record.modified_at,
        raw_url: url
      }

      assign(socket, preview: preview, modal: :preview)
    else
      put_flash(socket, :error, "Preview unavailable for this provider record.")
    end
  end

  defp put_ingest_result_flash(socket, {:ok, _jobs}),
    do: put_flash(socket, :info, "Ingestion started.")

  defp put_ingest_result_flash(socket, {:error, {:partial_failure, jobs, errors}}) do
    if jobs == [] do
      put_flash(
        socket,
        :error,
        "No selected records could be ingested (#{length(errors)} failed)."
      )
    else
      put_flash(
        socket,
        :warning,
        "Ingestion started for #{length(jobs)} item(s); #{length(errors)} failed."
      )
    end
  end

  defp put_ingest_result_flash(socket, _), do: put_flash(socket, :error, "Ingestion failed.")

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
  defdelegate status_pill_classes(status), to: ZaqWeb.Live.BO.AI.IngestionComponents

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
