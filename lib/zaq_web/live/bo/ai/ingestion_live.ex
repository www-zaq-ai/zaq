# lib/zaq_web/live/bo/ai/ingestion_live.ex

defmodule ZaqWeb.Live.BO.AI.IngestionLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Live.BO.AI.IngestionComponents

  import ZaqWeb.Components.DesignSystem.IngestionFileStatus,
    only: [file_ingestion_status: 2, record_folder?: 1, record_path: 1]

  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.DataSource.CreateDocument
  alias Zaq.Agent.Tools.General.EncodeBase64
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Channels.Events, as: ChannelEvents
  alias Zaq.Channels.ProviderCatalog
  alias Zaq.Channels.WebhookUrl
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, ExternalSource, IngestJob}
  alias Zaq.NodeRouter
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.System
  alias ZaqWeb.Components.Drawer
  alias ZaqWeb.Live.BO.AI.BOActor
  alias ZaqWeb.Live.BO.PreviewHelpers

  import Ecto.Query

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

    source_scopes = enabled_data_source_sources()
    active_source = resolve_source_scope(params, source_scopes)
    provider = active_source_provider(active_source, Map.get(params, "provider"))
    data_source_enabled? = data_source_config_enabled?()

    action_capabilities = action_capabilities(provider)

    {:ok,
     socket
     |> assign(
       current_path: ingestion_path(provider),
       provider: provider,
       provider_config_id: active_source_config_id(active_source, provider),
       provider_folder_stack: [],
       provider_page: nil,
       provider_page_token: nil,
       provider_error: nil,
       current_dir: ".",
       breadcrumbs: [],
       entries: [],
       selected: MapSet.new(),
       records_by_path: %{},
       action_capabilities: action_capabilities,
       watch_supported: action_capabilities.watch,
       watch_disabled_reason: watch_disabled_reason(provider),
       create_item_supported: action_capabilities.create,
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
       jobs_drawer_open: false,
       ingest_toast: nil,
       ingest_mode: "async",
       source_scopes: source_scopes,
       active_source: active_source,
       active_source_id: source_scope_id(active_source),
       data_source_enabled?: data_source_enabled?,
       # Embedding readiness
       embedding_ready: System.embedding_ready?(),
       # Permission sharing
       share_modal_document_id: nil,
       share_modal_is_folder: false,
       share_modal_is_public: false,
       share_modal_original_is_public: false,
       share_modal_folder_path: nil,
       share_modal_source_file_id: nil,
       share_modal_removed?: false,
       share_modal_public_inherited?: false,
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
       modal_error: nil,
       watch_error_target: nil,
       watch_error_message: nil,
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
     |> load_jobs()
     |> load_entries()
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
    open_source_share_modal(socket, path, true)
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
         share_modal_is_public: Permissions.public?(doc),
         share_modal_original_is_public: Permissions.public?(doc),
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
    open_source_share_modal(socket, path, false)
  end

  def handle_event("toggle_public", _params, %{assigns: %{share_modal_read_only: true}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "toggle_public",
        _params,
        %{assigns: %{share_modal_public_inherited?: true}} = socket
      ),
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

    direct_count =
      socket.assigns.share_modal_permissions
      |> Enum.reject(&Map.get(&1, :inherited?, false))
      |> length()

    permissions =
      Enum.reject(socket.assigns.share_modal_permissions, &(&1.id == id or &1.id == id_str))

    {:noreply,
     assign(socket,
       share_modal_permissions: permissions,
       share_modal_removed?:
         direct_count > permissions |> Enum.reject(&Map.get(&1, :inherited?, false)) |> length(),
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

    grants = source_share_grants(socket.assigns.share_modal_permissions, pending, is_public)

    params = %{
      "config_id" => data_source_config_id(socket),
      "file_id" => confirm_source_file_id(socket),
      "grants" => grants
    }

    case dispatch_source_permission_sync(socket, params) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(
           modal: nil,
           modal_error: nil,
           share_modal_pending: [],
           share_modal_removed?: false
         )
         |> load_entries()
         |> put_flash(:info, "Permissions saved for \"#{name}\".")}

      {:error, reason} ->
        {:noreply, assign(socket, modal_error: "Permissions failed: #{inspect(reason)}")}
    end
  end

  # Data-source selection

  def handle_event("switch_source", %{"source" => "source:" <> source_id}, socket)
      when source_id != "" do
    case Enum.find(socket.assigns.source_scopes, &(&1.id == source_id)) do
      nil ->
        {:noreply, socket}

      %{provider: provider, config_id: config_id, scope_id: scope_id} ->
        {:noreply,
         push_navigate(socket,
           to: ingestion_path(provider, config_id: config_id, scope_id: scope_id)
         )}
    end
  end

  # File Browser

  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, navigate_provider(socket, path)}
  end

  def handle_event("go_back", _params, socket) do
    {:noreply, provider_go_back(socket)}
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

  def handle_event("toggle_watch_status", %{"path" => path} = params, socket) do
    case watch_target_for_path(socket, path) do
      {:ok, target, "error"} ->
        {:noreply, open_watch_error_modal(socket, target, Map.get(params, "watch_error"))}

      {:ok, target, status} when status in ["pending", "watched"] ->
        apply_watch_update(
          socket,
          [target],
          :clear,
          "Watching disabled for #{watch_target_label(target)}."
        )

      {:ok, target, _status} ->
        apply_watch_update(
          socket,
          [target],
          :request,
          "Watch setup requested for #{watch_target_label(target)}."
        )

      {:error, reason} ->
        {:noreply, put_flash(socket, :info, watch_skip_message(reason))}
    end
  end

  def handle_event("watch_selected", _params, socket) do
    targets = selected_watch_targets(socket, :request)
    apply_bulk_watch_update(socket, targets, :request, "Watch setup requested")
  end

  def handle_event("unwatch_selected", _params, socket) do
    targets = selected_watch_targets(socket, :clear)
    apply_bulk_watch_update(socket, targets, :clear, "Watching disabled")
  end

  def handle_event("retry_watch", _params, %{assigns: %{watch_error_target: target}} = socket)
      when is_map(target) do
    socket = close_watch_error_modal(socket)

    apply_watch_update(
      socket,
      [target],
      :request,
      "Watch setup requested for #{watch_target_label(target)}."
    )
  end

  def handle_event("retry_watch", _params, socket) do
    {:noreply, close_watch_error_modal(socket)}
  end

  # View Mode

  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) when mode in ~w(list grid) do
    {:noreply, assign(socket, view_mode: mode)}
  end

  # Modal: Upload

  def handle_event("show_upload_modal", _params, socket) do
    if socket.assigns.create_item_supported do
      {:noreply, assign(socket, modal: :upload, modal_error: nil)}
    else
      {:noreply, put_flash(socket, :info, "This data source does not support document creation.")}
    end
  end

  # Modal: New Folder

  def handle_event("show_new_folder_modal", _params, socket) do
    if socket.assigns.create_item_supported do
      {:noreply, assign(socket, modal: :new_folder, modal_name: "", modal_error: nil)}
    else
      {:noreply, put_flash(socket, :info, "This data source does not support document creation.")}
    end
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, modal_error: "Folder name cannot be empty.")}
    else
      case create_document(socket, %{name: name, kind: "folder"}) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> assign(modal: nil, modal_error: nil)
           |> load_entries()
           |> put_flash(:info, "Folder \"#{name}\" created.")}

        {:error, reason} ->
          {:noreply, assign(socket, modal_error: create_modal_error("Failed", reason))}
      end
    end
  end

  # Modal: Rename

  def handle_event("rename_item", %{"path" => path}, socket) do
    {:noreply,
     assign(socket,
       modal: :rename,
       modal_path: path,
       modal_name: record_display_name(socket, path),
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

      new_name == socket.assigns.modal_name or old_path == new_path ->
        {:noreply, assign(socket, modal: nil, modal_error: nil)}

      true ->
        do_rename(socket, old_path, new_path, new_name)
    end
  end

  # Modal: Delete single item

  def handle_event("delete_item", %{"path" => path}, socket) do
    {:noreply,
     assign(socket,
       modal: :delete,
       modal_path: path,
       modal_name: record_display_name(socket, path),
       modal_error: nil
     )}
  end

  def handle_event("confirm_delete", _params, socket) do
    result = delete_data_source_path(socket, socket.assigns.modal_path)

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(modal: nil, selected: MapSet.new(), modal_error: nil)
         |> load_entries()
         |> put_flash(:info, "\"#{socket.assigns.modal_name}\" deleted.")}

      {:ok, _result} ->
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
    if Map.get(socket.assigns.action_capabilities, :delete, false) do
      {:noreply, assign(socket, modal: :delete_selected, modal_error: nil)}
    else
      {:noreply, put_flash(socket, :info, "This data source does not support deletion.")}
    end
  end

  def handle_event("confirm_delete_selected", _params, socket) do
    results =
      Enum.map(socket.assigns.selected, fn path ->
        {path, delete_data_source_path(socket, path)}
      end)

    errors = Enum.reject(results, fn {_p, res} -> delete_success?(res) end)

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

  def handle_event("move_item", %{"path" => path}, socket) do
    if Map.get(socket.assigns.action_capabilities, :move, false) do
      {:noreply,
       socket
       |> assign(
         modal: :move,
         modal_path: path,
         modal_name: record_display_name(socket, path),
         modal_error: nil,
         move_current_dir: ".",
         move_breadcrumbs: []
       )
       |> load_move_folders(".")}
    else
      {:noreply, put_flash(socket, :info, "This data source does not support move operations.")}
    end
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
    {:noreply, close_watch_error_modal(socket)}
  end

  def handle_event("open_preview", %{"path" => path, "filename" => filename}, socket) do
    case preview_record(socket, path) do
      {:ok, record} -> {:noreply, open_record_preview(socket, record, filename)}
      :missing -> {:noreply, open_provider_preview(socket, path)}
    end
  end

  def handle_event("open_preview", %{"path" => path}, socket) do
    case preview_record(socket, path) do
      {:ok, record} -> {:noreply, open_record_preview(socket, record, nil)}
      :missing -> {:noreply, open_provider_preview(socket, path)}
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
    if socket.assigns.create_item_supported do
      {:noreply,
       assign(socket,
         modal: :add_raw,
         raw_filename: "",
         raw_content: "",
         modal_error: nil
       )}
    else
      {:noreply, put_flash(socket, :info, "This data source does not support document creation.")}
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
    trimmed_content = String.trim(content)

    cond do
      filename == "" ->
        {:noreply, assign(socket, modal_error: "Filename cannot be empty.")}

      trimmed_content == "" ->
        {:noreply, assign(socket, modal_error: "Content cannot be empty.")}

      true ->
        filename = ensure_md_extension(filename)

        case create_document(socket, %{
               name: filename,
               content: content,
               mime_type: "text/markdown"
             }) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(modal: nil, modal_error: nil, raw_filename: "", raw_content: "")
             |> load_entries()
             |> load_jobs()
             |> put_flash(:info, "\"#{filename}\" saved.")}

          {:error, reason} ->
            {:noreply, assign(socket, modal_error: create_modal_error("Save failed", reason))}
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
    if Map.get(socket.assigns.action_capabilities, :download, false) do
      records = selected_records(socket)
      result = dispatch_ingest_records(records, %{mode: socket.assigns.ingest_mode}, socket)

      socket =
        socket
        |> assign(selected: MapSet.new())
        |> load_jobs()
        # With Oban testing: :inline (E2E/ExUnit), async jobs finish before this handler
        # returns. Refresh entries now so the file browser shows terminal badges in the
        # same patch; PubSub {:job_updated, _} still refreshes for real async runs.
        |> load_entries()
        |> put_ingest_result_flash(result)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :info, "This data source does not support ingestion.")}
    end
  end

  def handle_event("dismiss_ingest_toast", _params, socket) do
    {:noreply, assign(socket, :ingest_toast, nil)}
  end

  def handle_event("open_jobs_drawer", _params, socket) do
    {:noreply, assign(socket, :jobs_drawer_open, true)}
  end

  def handle_event("close_jobs_drawer", _params, socket) do
    {:noreply, assign(socket, :jobs_drawer_open, false)}
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
      results =
        consume_uploaded_entries(socket, :files, fn %{path: tmp_path}, entry ->
          upload_entry(socket, tmp_path, entry)
        end)

      {uploaded, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

      socket =
        socket
        |> load_entries()
        |> put_upload_result_flash(uploaded, failed)
        |> push_event("folder_batch_done", %{})
        |> maybe_close_upload_modal(uploaded, failed)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp upload_entry(socket, tmp_path, entry) do
    relative =
      case entry.client_relative_path do
        path when is_binary(path) and path != "" -> path
        _ -> entry.client_name
      end

    binary = File.read!(tmp_path)

    with {:ok, %{encoded: encoded}} <-
           EncodeBase64.run(%{data: binary, variant: "standard", padding: true}, %{}),
         {:ok, result} <-
           create_document(socket, %{
             name: relative,
             content: encoded,
             encoding: "base64",
             mime_type: entry.client_type || "application/octet-stream"
           }) do
      case result do
        %{record: record} -> {:ok, {:ok, record.path || relative}}
        _ -> {:ok, {:ok, relative}}
      end
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  # Inline BO flash: the upload modal closes on success, so the banner is visible on the
  # page behind it. Compare `put_ingest_result_flash/2`, which needs a toast because the
  # jobs drawer opens over the page.
  defp put_upload_result_flash(socket, [], []), do: socket

  defp put_upload_result_flash(socket, uploaded, []) do
    put_flash(socket, :info, "#{length(uploaded)} file(s) uploaded.")
  end

  defp put_upload_result_flash(socket, [], failed) do
    put_flash(socket, :error, "Upload failed: #{upload_failure_reasons(failed)}")
  end

  defp put_upload_result_flash(socket, uploaded, failed) do
    put_flash(socket, :info, "#{length(uploaded)} file(s) uploaded. #{length(failed)} failed.")
  end

  defp upload_failure_reasons(failed) do
    failed
    |> Enum.map(fn {:error, reason} -> inspect(reason) end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp create_modal_error(prefix, reason) when is_binary(reason) do
    reason = String.replace_prefix(reason, "Data source document creation failed: ", "")
    "#{prefix}: #{reason}"
  end

  defp create_modal_error(prefix, reason), do: "#{prefix}: #{inspect(reason)}"

  defp maybe_close_upload_modal(socket, uploaded, failed) do
    if socket.assigns.modal == :upload and uploaded != [] and failed == [] do
      assign(socket, modal: nil)
    else
      socket
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

  defp do_rename(socket, old_path, _new_path, new_name) do
    case update_data_source_file(socket, old_path, %{"name" => new_name}) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(modal: nil, selected: MapSet.new(), modal_error: nil)
         |> load_entries()
         |> put_flash(:info, "Renamed to \"#{new_name}\".")}

      {:error, reason} ->
        {:noreply, assign(socket, modal_error: "Rename failed: #{inspect(reason)}")}
    end
  end

  defp do_move(socket, source, _dest, name, dest_dir) do
    case update_data_source_file(socket, source, %{
           "path" => data_source_parent(socket, dest_dir)
         }) do
      {:ok, _result} ->
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
    if Map.get(socket.assigns.action_capabilities, :list, false) do
      load_provider_entries(socket)
    else
      socket
      |> assign(entries: [], records_by_path: %{}, ingestion_map: %{})
      |> assign(provider_error: "This data source does not support browsing.")
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
    case dispatch_list_files(socket.assigns.provider, provider_list_params(socket), socket) do
      {:ok, %Zaq.Contracts.RecordPage{} = page} ->
        records = Enum.map(page.records || [], &with_provider_attrs(&1, socket))
        {records, ingestion_map} = enrich_provider_records(records, socket)

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

  # Refresh as soon as chunks are scheduled so the primary record shows progress
  # before chunk embedding finishes.
  defp maybe_refresh_entries_after_job(socket, %{
         status: "processing",
         total_chunks: total,
         ingested_chunks: 0
       })
       when is_integer(total) and total > 0 do
    load_entries(socket)
  end

  defp maybe_refresh_entries_after_job(socket, _job), do: socket

  defp enabled_data_source_sources do
    ChannelConfig
    |> where([c], c.kind == "data_source" and c.enabled == true)
    |> Repo.all()
    |> Enum.sort_by(&{&1.provider, &1.name})
    |> Enum.flat_map(&source_scopes_for_config/1)
  end

  defp data_source_config_enabled? do
    ChannelConfig
    |> where([c], c.kind == "data_source" and c.enabled == true)
    |> Repo.exists?()
  end

  defp source_scopes_for_config(config) do
    case dispatch_source_scopes(config.provider, %{"config_id" => config.id}) do
      {:ok, scopes} when is_list(scopes) -> Enum.map(scopes, &source_scope_nav(config, &1))
      _ -> []
    end
  end

  defp source_scope_nav(config, scope) do
    provider = scope |> scope_value(:provider) |> source_scope_string(config.provider)
    scope_id = scope |> scope_value(:scope_id) |> source_scope_string(config.id)
    config_id = scope_value(scope, :config_id) || config.id
    id = source_scope_id(provider, config_id, scope_id)

    %{
      id: id,
      provider: provider,
      config_id: config_id,
      scope_id: scope_id,
      filters: scope_value(scope, :filters) || %{},
      label:
        scope_value(scope, :label) ||
          ProviderCatalog.label(config.provider),
      path: ingestion_path(provider)
    }
  end

  defp scope_value(scope, key) when is_map(scope) do
    Map.get(scope, key) || Map.get(scope, to_string(key))
  end

  defp source_scope_string(nil, fallback), do: to_string(fallback)
  defp source_scope_string(value, _fallback), do: to_string(value)

  defp source_scope_id(nil), do: nil
  defp source_scope_id(%{id: id}), do: id

  defp source_scope_id(provider, config_id, scope_id) do
    Enum.join([provider, to_string(config_id), scope_id], ":")
  end

  defp resolve_source_scope(params, source_scopes) do
    requested_provider = Map.get(params, "provider")
    requested_config_id = Map.get(params, "config_id")
    requested_scope_id = Map.get(params, "scope_id")

    matched_scope =
      Enum.find(source_scopes, fn scope ->
        provider_match? = is_nil(requested_provider) or scope.provider == requested_provider

        config_match? =
          is_nil(requested_config_id) or to_string(scope.config_id) == requested_config_id

        scope_match? = is_nil(requested_scope_id) or scope.scope_id == requested_scope_id

        provider_match? and config_match? and scope_match?
      end)

    cond do
      matched_scope -> matched_scope
      is_nil(requested_provider) -> List.first(source_scopes)
      true -> nil
    end
  end

  defp active_source_provider(%{provider: provider}, _requested), do: provider
  defp active_source_provider(nil, requested) when is_binary(requested), do: requested
  defp active_source_provider(nil, _requested), do: nil

  defp active_source_config_id(%{config_id: config_id}, _provider), do: config_id
  defp active_source_config_id(nil, provider), do: provider_config_id(provider)

  defp ingestion_call(fun, args) do
    call_module = Zaq.Config.get(:zaq, :ingestion_call_module, NodeRouter, [])
    call_module.invoke(:ingestion, Ingestion, fun, args)
  end

  defp dispatch_list_files(provider, params, socket) do
    opts = [action: :data_source_list_files]
    opts = Keyword.put(opts, :data_source_bridge_module, data_source_bridge_module())

    Event.new(%{provider: provider, params: params}, :channels,
      opts: opts,
      actor: BOActor.build(socket.assigns.current_user)
    )
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp dispatch_data_source_action(action, provider, params, socket) do
    opts = [action: action]
    opts = Keyword.put(opts, :data_source_bridge_module, data_source_bridge_module())

    Event.new(%{provider: provider, params: params}, :channels,
      opts: opts,
      actor: BOActor.build(socket.assigns.current_user)
    )
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp create_document(socket, attrs) when is_map(attrs) do
    params =
      attrs
      |> Map.put(:provider, create_document_provider(socket))
      |> Map.merge(create_document_destination(socket))

    action_module =
      Zaq.Config.get(:zaq, :ingestion_create_document_module, CreateDocument, [])

    action_module.run(params, create_document_context(socket))
  end

  defp create_document_provider(%{assigns: %{provider: provider}}),
    do: capability_provider(provider)

  defp create_document_destination(socket) do
    folder = List.last(socket.assigns.provider_folder_stack)
    parent_id = provider_parent_id(folder) || active_source_parent(socket)

    %{
      config_id:
        socket.assigns.provider_config_id && to_string(socket.assigns.provider_config_id),
      parent_id: parent_id,
      path: parent_id
    }
  end

  defp provider_parent_id(%{id: id}) when is_binary(id) and id not in ["", "."], do: id
  defp provider_parent_id(_folder), do: nil

  defp active_source_parent(socket) do
    socket
    |> active_source_filters()
    |> Map.get("parent")
  end

  defp data_source_parent(socket, dir) when dir in [nil, "", "."],
    do: active_source_parent(socket)

  defp data_source_parent(socket, dir) do
    case active_source_parent(socket) do
      parent when is_binary(parent) and parent not in ["", "."] -> Path.join(parent, dir)
      _ -> dir
    end
  end

  defp create_document_context(socket) do
    %{
      actor: BOActor.build(socket.assigns.current_user),
      event_opts: [data_source_bridge_module: data_source_bridge_module()]
    }
  end

  defp update_data_source_file(socket, path, attrs) do
    with {:ok, record} <- data_source_record(socket, path) do
      params = Map.put(attrs, "file_id", record.id)

      dispatch_data_source_action(
        :data_source_update_file,
        data_source_provider(socket),
        params,
        socket
      )
    end
  end

  defp delete_data_source_path(socket, path) do
    with {:ok, record} <- data_source_record(socket, path) do
      record = with_provider_attrs(record, socket)

      result =
        dispatch_data_source_delete(record, socket)

      if delete_success?(result) do
        dispatch_data_source_removed(record)
      end

      result
    end
  end

  defp dispatch_data_source_delete(record, socket) do
    opts = [action: :data_source_delete_file]
    opts = Keyword.put(opts, :data_source_bridge_module, data_source_bridge_module())

    Event.new(%{record: record}, :channels,
      opts: opts,
      actor: BOActor.build(socket.assigns.current_user)
    )
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  defp delete_success?(:ok), do: true
  defp delete_success?({:ok, _result}), do: true
  defp delete_success?(_result), do: false

  defp data_source_record(socket, path) do
    case Map.get(socket.assigns.records_by_path, path) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp record_display_name(socket, path) do
    case data_source_record(socket, path) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _ when is_binary(path) -> Path.basename(path)
      _ -> ""
    end
  end

  defp share_record(socket, path) do
    with {:ok, record} <- data_source_record(socket, path) do
      {:ok, with_provider_attrs(record, socket)}
    end
  end

  defp dispatch_data_source_removed(record) do
    request = %{
      provider: ExternalSource.provider(record),
      config_id: ExternalSource.config_id(record),
      force_delete: true,
      signals: [%{removed: true, record: record}]
    }

    Event.new(request, :ingestion, opts: [action: :process_data_source_changes])
    |> NodeRouter.dispatch()
  end

  defp data_source_bridge_module do
    Application.get_env(:zaq, :ingestion_data_source_bridge_module, DataSourceBridge)
  end

  defp dispatch_ingest_records([], _params, _socket), do: {:ok, []}

  defp dispatch_ingest_records(records, params, socket) do
    # Phase 1 sends canonical records to ingestion. Future external data-source
    # records should follow this same path so BO never branches on source origin.
    event =
      Event.new(%{records: records, params: params}, :ingestion,
        opts: [action: :ingest_records],
        actor: BOActor.build(socket.assigns.current_user)
      )

    router_module =
      Zaq.Config.get(:zaq, :ingestion_node_router_module, NodeRouter, [])

    router_module.dispatch(event).response
  end

  defp dispatch_source_scopes(provider, params) do
    opts = [
      action: :data_source_list_source_scopes,
      data_source_bridge_module: data_source_bridge_module()
    ]

    event = Event.new(%{provider: provider, params: params}, :channels, opts: opts)

    NodeRouter.dispatch(event).response
  end

  defp selected_records(socket) do
    socket.assigns.selected
    |> Enum.map(&Map.get(socket.assigns.records_by_path, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&with_provider_attrs(&1, socket))
  end

  defp records_by_path(entries), do: Map.new(entries, &{record_path(&1), &1})

  defp open_source_share_modal(socket, path, folder?) do
    with {:ok, record} <- share_record(socket, path),
         {:ok, source_file_id} <- source_file_id(socket, path, record, folder?),
         {:ok, permissions, public?, public_inherited?} <-
           source_permissions(socket, source_file_id) do
      all_targets = socket.assigns.share_modal_all_targets

      {:noreply,
       assign(socket,
         modal: :share,
         modal_path: path,
         modal_name: record.name || Path.basename(path),
         modal_error: nil,
         share_modal_is_folder: folder?,
         share_modal_is_public: public? and not public_inherited?,
         share_modal_original_is_public: public? and not public_inherited?,
         share_modal_folder_path: if(folder?, do: path, else: nil),
         share_modal_document_id: nil,
         share_modal_source_file_id: source_file_id,
         share_modal_removed?: false,
         share_modal_public_inherited?: public_inherited?,
         share_modal_permissions: permissions,
         share_modal_pending: [],
         share_modal_targets_options: filtered_targets(all_targets, permissions, []),
         share_modal_read_only: false,
         share_modal_notice: nil
       )}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Permissions unavailable: #{inspect(reason)}")}
    end
  end

  defp source_file_id(_socket, _path, record, _folder?), do: remote_source_file_id(record)

  defp remote_source_file_id(%{id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp remote_source_file_id(_record), do: {:error, :missing_source_file_id}

  defp source_permissions(socket, file_id) do
    params = %{"config_id" => data_source_config_id(socket), "file_id" => file_id}

    case dispatch_data_source_action(
           :data_source_list_permissions,
           data_source_provider(socket),
           params,
           socket
         ) do
      {:ok, %{records: records} = page} ->
        public? = Map.get(page, :public?, Enum.any?(records, &public_permission_record?/1))
        public_inherited? = Enum.any?(records, &public_permission_inherited?/1)

        {:ok, Enum.map(records, &modal_permission/1) |> Enum.reject(&is_nil/1), public?,
         public_inherited?}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp confirm_source_file_id(%{assigns: %{share_modal_source_file_id: id}})
       when is_binary(id) and id != "",
       do: id

  defp confirm_source_file_id(socket) do
    case source_file_id(
           socket,
           socket.assigns.modal_path,
           %{},
           socket.assigns.share_modal_is_folder
         ) do
      {:ok, id} -> id
      _ -> socket.assigns.share_modal_source_file_id
    end
  end

  defp modal_permission(%Record{attributes: %{"type" => "public"}}), do: nil

  defp modal_permission(%Record{
         id: id,
         attributes: %{"type" => "person", "target_id" => target_id} = attrs
       }) do
    person = People.get_person(parse_int(target_id))

    %{
      id: parse_int(id),
      person: person,
      team: nil,
      access_rights: Map.get(attrs, "access_rights", ["read"]),
      inherited?: Map.get(attrs, "inherited", false)
    }
  end

  defp modal_permission(%Record{
         id: id,
         attributes: %{"type" => "team", "target_id" => target_id} = attrs
       }) do
    team = People.get_team(parse_int(target_id))

    %{
      id: parse_int(id),
      person: nil,
      team: team,
      access_rights: Map.get(attrs, "access_rights", ["read"]),
      inherited?: Map.get(attrs, "inherited", false)
    }
  end

  defp modal_permission(_record), do: nil

  defp public_permission_record?(%Record{attributes: %{"type" => "public"}}), do: true
  defp public_permission_record?(_record), do: false

  defp public_permission_inherited?(%Record{attributes: %{"type" => "public"} = attrs}),
    do: Map.get(attrs, "inherited", false)

  defp public_permission_inherited?(_record), do: false

  defp source_share_grants(permissions, pending, public?) do
    current =
      permissions
      |> Enum.reject(&Map.get(&1, :inherited?, false))
      |> Enum.map(fn permission ->
        cond do
          permission.person ->
            %{
              "type" => "person",
              "target_id" => permission.person.id,
              "access_rights" => permission.access_rights
            }

          permission.team ->
            %{
              "type" => "team",
              "target_id" => permission.team.id,
              "access_rights" => permission.access_rights
            }
        end
      end)

    pending =
      Enum.map(pending, fn entry ->
        %{
          "type" => to_string(entry.type),
          "target_id" => entry.id,
          "access_rights" => entry.access_rights
        }
      end)

    public = if public?, do: [%{"type" => "public", "access_rights" => ["read"]}], else: []
    current ++ pending ++ public
  end

  defp dispatch_source_permission_sync(socket, params) do
    event =
      %{provider: data_source_provider(socket), params: params}
      |> Event.new(:ingestion,
        opts: [
          action: :sync_data_source_permissions,
          data_source_bridge_module: data_source_bridge_module()
        ],
        actor: BOActor.build(socket.assigns.current_user)
      )

    router_module = Zaq.Config.get(:zaq, :ingestion_node_router_module, NodeRouter, [])
    router_module.dispatch(event).response
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_binary(value), do: String.to_integer(value)

  defp access_status(record, fallback) do
    case permission_summary(record) do
      nil -> fallback
      summary -> Map.merge(fallback, summary)
    end
  end

  defp permission_summary(%{permissions: permissions}) when is_list(permissions) do
    direct_public? =
      Enum.any?(permissions, &(permission_type?(&1, "public") and not permission_inherited?(&1)))

    inherited_public? =
      Enum.any?(permissions, &(permission_type?(&1, "public") and permission_inherited?(&1)))

    principal_count =
      permissions
      |> Enum.reject(&permission_type?(&1, "public"))
      |> Enum.map(&permission_principal_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    %{
      permissions_count: principal_count,
      is_public: direct_public? or inherited_public?,
      public_inherited?: inherited_public?,
      can_share?: true
    }
  end

  defp permission_summary(_record), do: nil

  defp permission_type?(permission, type), do: permission_attr(permission, :type) == type

  defp permission_inherited?(permission),
    do:
      permission_attr(permission, :inherited?) == true or
        permission_attr(permission, :inherited) == true

  defp permission_principal_key(permission) do
    case {permission_attr(permission, :type),
          permission_attr(permission, :target_id) || permission_attr(permission, :id)} do
      {type, id} when type in ["person", "team"] and not is_nil(id) -> {type, to_string(id)}
      _ -> nil
    end
  end

  defp permission_attr(%Record{attributes: attrs} = record, key) do
    Map.get(attrs || %{}, Atom.to_string(key)) || Map.get(attrs || %{}, key) ||
      Map.get(record, key)
  end

  defp permission_attr(permission, key) when is_map(permission) do
    Map.get(permission, key) || Map.get(permission, Atom.to_string(key))
  end

  defp permission_attr(_permission, _key), do: nil

  defp selected_watchable_count(selected, records_by_path, ingestion_map) do
    selected
    |> Enum.count(fn path ->
      case Map.get(records_by_path, path) do
        nil ->
          false

        entry ->
          watchable_status?(entry, ingestion_map) and not watched_status?(entry, ingestion_map)
      end
    end)
  end

  defp selected_watched_count(selected, records_by_path, ingestion_map) do
    selected
    |> Enum.count(fn path ->
      case Map.get(records_by_path, path) do
        nil -> false
        entry -> watchable_status?(entry, ingestion_map) and watched_status?(entry, ingestion_map)
      end
    end)
  end

  defp watchable_status?(entry, ingestion_map) do
    status = file_ingestion_status(ingestion_map, entry.name)
    Map.get(status, :watchable?, false)
  end

  defp watched_status?(entry, ingestion_map) do
    status = file_ingestion_status(ingestion_map, entry.name)
    status.watch_status in ["pending", "watched"]
  end

  defp selected_watch_targets(socket, mode) when mode in [:request, :clear] do
    socket.assigns.selected
    |> Enum.map(&watch_target_for_path(socket, &1))
    |> Enum.flat_map(fn
      {:ok, target, status} when mode == :request and status not in ["pending", "watched"] ->
        [target]

      {:ok, target, status} when mode == :clear and status in ["pending", "watched", "error"] ->
        [target]

      _ ->
        []
    end)
  end

  defp watch_target_for_path(socket, path) do
    with %{} = entry <- Map.get(socket.assigns.records_by_path, path) || {:error, :missing},
         status = file_ingestion_status(socket.assigns.ingestion_map, entry.name),
         true <-
           socket.assigns.watch_supported or
             status.watch_status in ["pending", "watched", "error"] or
             watch_support_error(socket),
         true <- Map.get(status, :watchable?, false) || {:error, :not_ingested},
         true <- not Map.get(status, :watch_inherited?, false) || {:error, :watch_inherited} do
      {:ok, watch_target(socket, entry), status.watch_status || "unwatched"}
    end
  end

  defp watch_target(socket, entry) do
    kind = if record_folder?(entry), do: :folder, else: :file
    source = ExternalSource.source(with_provider_attrs(entry, socket))

    target = %{source: source, kind: kind, label: entry.name || record_path(entry)}

    Map.put(target, :provider_file_id, to_string(entry.id))
  end

  defp watch_support_error(%{assigns: %{watch_disabled_reason: reason}})
       when is_binary(reason) and reason != "",
       do: {:error, :watch_disabled}

  defp watch_support_error(_socket), do: {:error, :unsupported}

  defp apply_watch_update(socket, targets, :request, message) do
    result = apply_watch_request(socket, targets)

    {:noreply,
     socket
     |> load_entries()
     |> put_watch_result_flash(result, message)}
  end

  defp apply_watch_update(socket, targets, :clear, message) do
    result = apply_watch_clear(socket, targets)

    {:noreply,
     socket
     |> load_entries()
     |> put_watch_result_flash(result, message)}
  end

  defp apply_bulk_watch_update(socket, [], _mode, _message) do
    {:noreply, put_flash(socket, :info, "No selected items can be updated.")}
  end

  defp apply_bulk_watch_update(socket, targets, mode, message) do
    result =
      case mode do
        :request -> apply_watch_request(socket, targets)
        :clear -> apply_watch_clear(socket, targets)
      end

    {:noreply,
     socket
     |> assign(selected: MapSet.new())
     |> load_entries()
     |> put_watch_result_flash(result, "#{message} for #{length(targets)} item(s).")}
  end

  defp open_watch_error_modal(socket, target, watch_error) do
    assign(socket,
      modal: :watch_error,
      modal_error: nil,
      modal_name: watch_target_label(target),
      watch_error_target: target,
      watch_error_message: normalize_watch_error(watch_error)
    )
  end

  defp close_watch_error_modal(socket) do
    assign(socket,
      modal: nil,
      modal_error: nil,
      watch_error_target: nil,
      watch_error_message: nil
    )
  end

  defp normalize_watch_error(error) when is_binary(error) do
    case String.trim(error) do
      "" -> "Watch setup failed."
      value -> value
    end
  end

  defp normalize_watch_error(_error), do: "Watch setup failed."

  defp apply_watch_request(%{assigns: %{watch_supported: false}} = _socket, _targets),
    do: %{updated: 0, skipped: 0}

  defp apply_watch_request(socket, targets), do: request_provider_watches(socket, targets)

  defp apply_watch_clear(socket, targets), do: clear_provider_watches(socket, targets)

  defp request_provider_watches(socket, targets) do
    watcher_needed? = watched_provider_document_count(socket) == 0

    targets
    |> Enum.reduce(%{updated: 0, skipped: 0, watcher_ready?: not watcher_needed?}, fn target,
                                                                                      acc ->
      _ = ingestion_call(:request_watch, [[target]])

      socket
      |> maybe_dispatch_provider_watch(target, acc)
      |> update_provider_watch_result(target, acc)
    end)
    |> Map.drop([:watcher_ready?])
  end

  defp maybe_dispatch_provider_watch(socket, target, %{watcher_ready?: false}) do
    target
    |> provider_watch_params(socket)
    |> dispatch_provider_watch(socket)
  end

  defp maybe_dispatch_provider_watch(_socket, _target, %{watcher_ready?: true}) do
    {:ok, %{status: "watched"}}
  end

  defp update_provider_watch_result({:ok, result}, target, acc) do
    case ingestion_call(:mark_watch_active, [target, result]) do
      {:ok, _doc} -> %{acc | updated: acc.updated + 1, watcher_ready?: true}
      _ -> %{acc | skipped: acc.skipped + 1}
    end
  end

  defp update_provider_watch_result({:error, reason}, target, acc) do
    _ = ingestion_call(:mark_watch_error, [target, reason])
    %{acc | skipped: acc.skipped + 1}
  end

  defp clear_provider_watches(socket, targets) do
    targets
    |> Enum.reduce(%{updated: 0, skipped: 0}, fn target, acc ->
      update_clear_watch_result(target, acc)
    end)
    |> maybe_stop_provider_watcher(socket)
  end

  defp maybe_stop_provider_watcher(%{updated: updated} = result, socket) when updated > 0 do
    if socket.assigns.watch_supported and watched_provider_document_count(socket) == 0 do
      case dispatch_provider_unwatch(socket) do
        :ok -> result
        {:ok, _result} -> result
        {:error, _reason} -> %{result | skipped: result.skipped + 1}
      end
    else
      result
    end
  end

  defp maybe_stop_provider_watcher(result, _socket), do: result

  defp update_clear_watch_result(target, acc) do
    case ingestion_call(:clear_watch, [[target]]) do
      %{updated: updated} when updated > 0 -> %{acc | updated: acc.updated + updated}
      _ -> %{acc | skipped: acc.skipped + 1}
    end
  end

  defp provider_watch_params(target, socket) do
    %{
      "config_id" => data_source_config_id(socket),
      "file_id" => Map.fetch!(target, :provider_file_id),
      "kind" => to_string(target.kind),
      "target_source" => target.source,
      "webhook_url" => channel_webhook_url(data_source_provider(socket))
    }
  end

  defp dispatch_provider_watch(params, socket) do
    case ChannelEvents.build_and_dispatch_data_source_watch_item_event(
           data_source_provider(socket),
           params,
           event_opts: [data_source_bridge_module: data_source_bridge_module()]
         ).response do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp dispatch_provider_unwatch(socket) do
    params = %{"target_source" => provider_config_watch_source(socket)}

    case ChannelEvents.build_and_dispatch_data_source_unwatch_item_event(
           data_source_provider(socket),
           params,
           event_opts: [data_source_bridge_module: data_source_bridge_module()]
         ).response do
      :ok -> :ok
      {:ok, _result} = ok -> ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp watched_provider_document_count(socket) do
    ingestion_call(:count_watched_provider_documents, [
      data_source_provider(socket),
      data_source_config_id(socket)
    ])
  end

  defp provider_config_watch_source(socket) do
    Enum.join(
      ["data_source", data_source_provider(socket), to_string(data_source_config_id(socket))],
      "/"
    )
  end

  defp channel_webhook_url(provider) do
    WebhookUrl.build(:data_source, provider)
  end

  defp data_source_provider(%{assigns: %{provider: provider}}), do: provider

  defp data_source_config_id(%{assigns: %{provider_config_id: config_id}}), do: config_id

  defp put_watch_result_flash(socket, %{updated: updated, skipped: 0}, message)
       when updated > 0 do
    put_flash(socket, :info, message)
  end

  defp put_watch_result_flash(socket, %{updated: updated, skipped: skipped}, message)
       when updated > 0 do
    put_flash(socket, :info, "#{message} #{skipped} item(s) skipped.")
  end

  defp put_watch_result_flash(socket, _result, _message) do
    put_flash(socket, :info, "No watch status was changed.")
  end

  defp watch_target_label(%{label: label}) when is_binary(label) and label != "",
    do: "\"#{label}\""

  defp watch_target_label(_target), do: "this item"

  defp watch_skip_message(:unsupported), do: "Watching is not supported for this data source."

  defp watch_skip_message(:watch_disabled),
    do: "Set System Configuration > Global > Base URL to enable external data-source watching."

  defp watch_skip_message(:watch_inherited), do: "This item is watched through its parent folder."
  defp watch_skip_message(:not_ingested), do: "Ingest this item before watching it."
  defp watch_skip_message(_reason), do: "This item cannot be watched."

  defp enrich_provider_records(records, socket) do
    documents_by_source = provider_documents_by_source(records)
    permission_counts = provider_document_permission_counts(documents_by_source)
    inherited_watch = provider_inherited_watch(socket)
    latest_jobs_by_source = latest_jobs_by_source(socket.assigns.jobs)

    Enum.map_reduce(records, %{}, fn record, acc ->
      source = ExternalSource.source(record)
      doc = Map.get(documents_by_source, source)

      status =
        record
        |> provider_record_status(doc, permission_counts, inherited_watch, socket)
        |> overlay_latest_job_status(source, latest_jobs_by_source)

      {record, Map.put(acc, record.name, status)}
    end)
  end

  defp latest_jobs_by_source(jobs) do
    Enum.reduce(jobs, %{}, fn job, acc ->
      case job_source(job) do
        source when is_binary(source) -> Map.put_new(acc, source, job)
        _ -> acc
      end
    end)
  end

  defp job_source(%IngestJob{file_path: "data_source/" <> _ = source}), do: source
  defp job_source(_), do: nil

  defp overlay_latest_job_status(status, source, latest_jobs_by_source) do
    case Map.get(latest_jobs_by_source, source) do
      %IngestJob{status: job_status} when job_status in ["pending", "processing", "failed"] ->
        Map.put(status, :job_status, job_status)

      _ ->
        status
    end
  end

  defp provider_inherited_watch(%{assigns: %{current_dir: current_dir}} = socket)
       when is_binary(current_dir) and current_dir not in ["", "root"] do
    Ingestion.data_source_inherited_watch(
      socket.assigns.provider,
      socket.assigns.provider_config_id,
      current_dir
    )
  end

  defp provider_inherited_watch(_socket), do: nil

  defp provider_documents_by_source(records) do
    records
    |> Enum.map(&ExternalSource.source/1)
    |> Document.list_by_sources()
    |> Map.new(&{&1.source, &1})
  end

  defp provider_document_permission_counts(documents_by_source) do
    documents_by_source
    |> Map.values()
    |> Enum.map(& &1.id)
    |> Ingestion.count_document_permissions()
  end

  defp preview_record(socket, path) do
    case Map.get(socket.assigns.records_by_path, path) do
      nil -> :missing
      record -> {:ok, with_provider_attrs(record, socket)}
    end
  end

  defp open_record_preview(socket, record, filename) do
    cond do
      is_binary(record.url) and record.url != "" ->
        open_provider_preview(socket, record)

      record.materialization_handle ->
        socket
        |> PreviewHelpers.open_preview(record, :modal)
        |> maybe_override_preview_filename(filename)

      true ->
        put_flash(socket, :error, "Preview unavailable for this provider record.")
    end
  end

  defp maybe_override_preview_filename(socket, filename)
       when is_binary(filename) and filename != "" do
    case socket.assigns.preview do
      %{filename: _} = preview -> assign(socket, preview: %{preview | filename: filename})
      _ -> socket
    end
  end

  defp maybe_override_preview_filename(socket, _filename), do: socket

  defp provider_record_status(record, doc, permission_counts, inherited_watch, socket)

  defp provider_record_status(
         %{kind: kind} = record,
         doc,
         _permission_counts,
         inherited_watch,
         socket
       )
       when kind in [:folder, "folder"] do
    watch_state = Ingestion.data_source_record_watch_state(doc, inherited_watch)

    record
    |> editable_access_status(socket, %{})
    |> Map.merge(%{
      type: :directory,
      total_size: 0,
      file_count: 0,
      ingested_count: 0,
      watch_status: watch_state.watch_status,
      watch_error: watch_state.watch_error,
      watch_inherited?: watch_state.watch_inherited?,
      watchable?: true
    })
  end

  defp provider_record_status(record, nil, _permission_counts, inherited_watch, socket) do
    watch_state = Ingestion.data_source_record_watch_state(nil, inherited_watch)

    record
    |> editable_access_status(socket, %{
      permissions_count: 0,
      is_public: false,
      can_share?: false
    })
    |> Map.merge(%{
      ingested_at: nil,
      stale?: false,
      watch_status: watch_state.watch_status,
      watch_error: watch_state.watch_error,
      watch_inherited?: watch_state.watch_inherited?,
      watchable?: Ingestion.data_source_record_watch_active?(watch_state)
    })
  end

  defp provider_record_status(record, doc, permission_counts, inherited_watch, socket) do
    ingested? = not is_nil(doc.content)

    stale? =
      ingested? && record.modified_at && doc.updated_at &&
        DateTime.compare(record.modified_at, doc.updated_at) == :gt

    watch_state = Ingestion.data_source_record_watch_state(doc, inherited_watch)

    record
    |> editable_access_status(socket, %{
      permissions_count: Map.get(permission_counts, to_string(doc.id), 0),
      is_public: Permissions.public?(doc),
      can_share?: socket.assigns.action_capabilities.share
    })
    |> Map.merge(%{
      ingested_at: if(ingested?, do: doc.updated_at),
      stale?: stale? || false,
      watch_status: watch_state.watch_status,
      watch_error: watch_state.watch_error,
      watch_inherited?: watch_state.watch_inherited?,
      watchable?: ingested?
    })
  end

  defp editable_access_status(record, socket, fallback) do
    if socket.assigns.action_capabilities.share do
      access_status(record, fallback)
    else
      fallback
    end
  end

  defp with_provider_attrs(record, socket) do
    attrs =
      record
      |> Map.get(:attributes, %{})
      |> Map.put("provider", socket.assigns.provider)
      |> put_present("config_id", socket.assigns.provider_config_id)
      |> Map.put_new("config_id", Map.get(record.attributes || %{}, "config_id"))
      |> Map.put_new("provider_record_id", record.id)
      |> Map.put("provider_url", record.url)
      |> Map.put("provider_mime_type", record.mime_type)

    %{record | attributes: attrs}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp provider_label(provider) when is_binary(provider) do
    provider
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp provider_label(_provider), do: "the data source"

  defp ingestion_path(nil), do: "/bo/ingestion"
  defp ingestion_path(provider), do: "/bo/ingestion/#{provider}"

  defp ingestion_path(provider, opts) do
    query =
      opts
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    case query do
      "" -> ingestion_path(provider)
      query -> ingestion_path(provider) <> "?" <> query
    end
  end

  defp action_capabilities(provider) do
    resolved = capability_snapshot_resolved(provider)

    %{
      create: capability_resolved?(resolved, :create_item),
      update: capability_resolved?(resolved, :update_item),
      move: capability_resolved?(resolved, :update_item),
      delete: capability_resolved?(resolved, :delete_item),
      list: capability_resolved?(resolved, :list_items),
      download: capability_resolved?(resolved, :download_items),
      share: capability_resolved?(resolved, :manage_item_permissions),
      watch: global_base_url_present?() and capability_resolved?(resolved, :watch_changes_webhook)
    }
  end

  defp watch_disabled_reason(_provider) do
    unless global_base_url_present?() do
      "Set System Configuration > Global > Base URL to enable external data-source watching."
    end
  end

  defp global_base_url_present? do
    case System.get_global_base_url() do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp capability_snapshot_resolved(provider) do
    provider
    |> capability_provider()
    |> dispatch_capability_snapshot(capability_params(provider))
    |> case do
      {:ok, %{resolved: resolved}} when is_map(resolved) ->
        resolved

      %{resolved: resolved} when is_map(resolved) ->
        resolved

      _ ->
        %{}
    end
  end

  defp capability_provider(provider), do: provider

  defp capability_params(provider), do: maybe_config_param(provider_config_id(provider))

  defp maybe_config_param(nil), do: %{}
  defp maybe_config_param(id), do: %{"config_id" => id}

  defp dispatch_capability_snapshot(provider, params) do
    opts = [action: :channel_capability_snapshot, bridge_module: data_source_bridge_module()]

    params
    |> Map.put(:provider, provider)
    |> Event.new(:channels, opts: opts)
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  rescue
    _ -> {:error, :unsupported}
  end

  defp capability_resolved?(resolved, capability) do
    value = Map.get(resolved, capability) || Map.get(resolved, to_string(capability))
    not is_nil(value) and value != false
  end

  defp provider_config_id(nil), do: nil

  defp provider_config_id(provider) do
    case ChannelConfig.get_by_provider(provider) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp provider_list_params(socket) do
    folder = List.last(socket.assigns.provider_folder_stack)
    source_filters = active_source_filters(socket)

    filters =
      case folder do
        %{id: id} when is_binary(id) and id != "." ->
          Map.merge(source_filters, %{
            "parent" => data_source_parent(socket, id),
            "include_shared" => false
          })

        _ ->
          source_filters
      end

    %{
      "config_id" => socket.assigns.provider_config_id,
      "filters" => filters,
      "include_permissions" => true
    }
  end

  defp active_source_filters(%{assigns: %{active_source: %{filters: filters}}})
       when is_map(filters),
       do: filters

  defp active_source_filters(_socket), do: %{}

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

  defp open_provider_preview(socket, record_or_id)

  defp open_provider_preview(socket, id) when is_binary(id) do
    case Map.get(socket.assigns.records_by_path, id) do
      nil -> put_flash(socket, :error, "Preview is unavailable for this provider record.")
      record -> open_provider_preview(socket, record)
    end
  end

  defp open_provider_preview(socket, record) when is_map(record) do
    url = Map.get(record, :url)

    if is_binary(url) and url != "" do
      preview = %{
        relative_path: url,
        filename: record.name || record.id,
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

  defp open_provider_preview(socket, _record),
    do: put_flash(socket, :error, "Preview unavailable for this provider record.")

  defp put_ingest_result_flash(socket, {:ok, _jobs}) do
    socket
    |> assign(:jobs_drawer_open, true)
    |> assign(:ingest_toast, %{kind: :info, message: "Ingestion started."})
  end

  defp put_ingest_result_flash(socket, {:error, {:partial_failure, jobs, errors}}) do
    if jobs == [] do
      put_flash(
        socket,
        :error,
        "No selected records could be ingested (#{length(errors)} failed)."
      )
    else
      socket
      |> assign(:jobs_drawer_open, true)
      |> assign(:ingest_toast, %{
        kind: :info,
        message: "Ingestion started for #{length(jobs)} item(s); #{length(errors)} failed."
      })
    end
  end

  defp put_ingest_result_flash(socket, _), do: put_flash(socket, :error, "Ingestion failed.")

  def active_jobs_count(jobs) when is_list(jobs) do
    Enum.count(jobs, &(&1.status in ~w(pending processing)))
  end

  defp load_move_folders(socket, dir) do
    moving_path = socket.assigns.modal_path

    params = %{
      "filters" => %{"parent" => data_source_parent(socket, dir)},
      "include_permissions" => false
    }

    case dispatch_list_files(data_source_provider(socket), params, socket) do
      {:ok, %Zaq.Contracts.RecordPage{records: records}} ->
        folders =
          records
          |> Enum.filter(fn record ->
            record_folder?(record) and record_path(record) != moving_path
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
      |> Enum.reject(&(&1.system_key == "everyone"))
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
