# lib/zaq_web/live/bo/ai/ingestion_live.ex

defmodule ZaqWeb.Live.BO.AI.IngestionLive do
  use ZaqWeb, :live_view

  import Ecto.Query
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, FileExplorer}
  alias Zaq.Repo

  @allowed_extensions ~w(.md .txt .pdf)

  def mount(_params, _session, socket) do
    if connected?(socket), do: Ingestion.subscribe()

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
       raw_filename: ""
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

      case FileExplorer.create_directory(path) do
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
    result = do_delete(socket.assigns.modal_path, socket.assigns.modal_type)

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
    results =
      Enum.map(socket.assigns.selected, fn path ->
        case FileExplorer.file_info(path) do
          {:ok, %{type: :directory}} -> {path, FileExplorer.delete_directory(path)}
          {:ok, %{type: :file}} -> {path, FileExplorer.delete(path)}
          _ -> {path, {:error, :not_found}}
        end
      end)

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

        case FileExplorer.upload(dest, content) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(modal: nil, modal_error: nil, raw_filename: "", raw_content: "")
             |> load_entries()
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

    for path <- socket.assigns.selected do
      case FileExplorer.file_info(path) do
        {:ok, %{type: :directory}} -> Ingestion.ingest_folder(path, mode)
        {:ok, %{type: :file}} -> Ingestion.ingest_file(path, mode)
        _ -> :skip
      end
    end

    {:noreply,
     socket
     |> assign(selected: MapSet.new())
     |> load_jobs()
     |> put_flash(:info, "Ingestion started.")}
  end

  def handle_event("retry_job", %{"id" => id}, socket) do
    case Ingestion.retry_job(id) do
      {:ok, _} -> {:noreply, socket |> load_jobs() |> put_flash(:info, "Job re-queued.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Retry failed: #{reason}")}
    end
  end

  def handle_event("cancel_job", %{"id" => id}, socket) do
    case Ingestion.cancel_job(id) do
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

  def handle_event("upload", _params, socket) do
    uploaded =
      consume_uploaded_entries(socket, :files, fn %{path: tmp_path}, entry ->
        binary = File.read!(tmp_path)
        dest = Path.join(socket.assigns.current_dir, entry.client_name)
        FileExplorer.upload(dest, binary)
      end)

    {:noreply,
     socket
     |> load_entries()
     |> put_flash(:info, "#{length(uploaded)} file(s) uploaded.")}
  end

  # ────────────────────────────────────────────────────────────────
  # handle_info/2
  # ────────────────────────────────────────────────────────────────

  def handle_info({:job_updated, _job}, socket) do
    {:noreply, load_jobs(socket)}
  end

  # ────────────────────────────────────────────────────────────────
  # Private helpers
  # ────────────────────────────────────────────────────────────────

  defp ensure_md_extension(filename) do
    if Path.extname(filename) == "", do: filename <> ".md", else: filename
  end

  defp load_ingestion_status(socket) do
    current_dir = socket.assigns.current_dir

    sources =
      socket.assigns.entries
      |> Enum.filter(&(&1.type == :file))
      |> Enum.map(fn entry ->
        path = Path.join(current_dir, entry.name)
        # Normalise: strip leading "./" so it matches what extract_source stores
        case path do
          "./" <> rest -> rest
          other -> other
        end
      end)

    documents =
      from(d in Zaq.Ingestion.Document, where: d.source in ^sources)
      |> Repo.all()
      |> Map.new(fn d -> {d.source, d} end)

    ingestion_map =
      socket.assigns.entries
      |> Enum.filter(&(&1.type == :file))
      |> Map.new(fn entry ->
        raw = Path.join(current_dir, entry.name)

        source =
          case raw do
            "./" <> rest -> rest
            other -> other
          end

        case Map.get(documents, source) do
          nil ->
            {entry.name, %{ingested_at: nil, stale?: false}}

          doc ->
            stale? = DateTime.compare(entry.modified_at, doc.updated_at) == :gt
            {entry.name, %{ingested_at: doc.updated_at, stale?: stale?}}
        end
      end)

    assign(socket, ingestion_map: ingestion_map)
  end

  defp parent_dir("."), do: "."

  defp parent_dir(path) do
    case Path.dirname(path) do
      "." -> "."
      parent -> parent
    end
  end

  defp do_rename(socket, old_path, new_path, new_name) do
    case FileExplorer.rename(old_path, new_path) do
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

  defp do_delete(path, "directory"), do: FileExplorer.delete_directory(path)

  defp do_delete(path, _type) do
    source =
      case path do
        "./" <> rest -> rest
        other -> other
      end

    case Document.get_by_source(source) do
      %Document{} = doc -> Document.delete(doc)
      nil -> :ok
    end

    FileExplorer.delete(path)
  end

  defp do_move(socket, source, dest, name, dest_dir) do
    case FileExplorer.rename(source, dest) do
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
    case FileExplorer.list(socket.assigns.current_dir) do
      {:ok, entries} ->
        sorted =
          Enum.sort_by(entries, fn e -> {if(e.type == :directory, do: 0, else: 1), e.name} end)

        socket
        |> assign(entries: sorted)
        |> load_ingestion_status()

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
        status -> [status: status]
      end

    assign(socket, jobs: Ingestion.list_jobs(opts))
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
    moving_path = socket.assigns.modal_path

    case FileExplorer.list(dir) do
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

  # ────────────────────────────────────────────────────────────────
  # Template helpers (public for HEEx)
  # ────────────────────────────────────────────────────────────────

  def format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def format_datetime(nil), do: "—"
  def format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  def status_color("pending"), do: "bg-black/5 text-black/40"
  def status_color("processing"), do: "bg-amber-100 text-amber-600"
  def status_color("completed"), do: "bg-emerald-100 text-emerald-700"
  def status_color("failed"), do: "bg-red-100 text-red-600"
  def status_color(_), do: "bg-black/5 text-black/30"

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
