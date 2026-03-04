defmodule ZaqWeb.Live.BO.IngestionLive do
  use ZaqWeb, :live_view

  alias Zaq.Ingestion
  alias Zaq.Ingestion.FileExplorer

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
       ingest_mode: "async"
     )
     |> load_entries()
     |> load_jobs()
     |> allow_upload(:files,
       accept: @allowed_extensions,
       max_entries: 10,
       max_file_size: 20_000_000
     )}
  end

  # --- File Browser ---

  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(current_dir: path, selected: MapSet.new())
     |> assign_breadcrumbs(path)
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

  # --- Ingestion ---

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, ingest_mode: mode)}
  end

  def handle_event("ingest_selected", _params, socket) do
    mode = String.to_existing_atom(socket.assigns.ingest_mode)

    for path <- socket.assigns.selected do
      _entry_full = Path.join(socket.assigns.current_dir, "")

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

  # --- Upload ---

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

  # --- PubSub ---

  def handle_info({:job_updated, _job}, socket) do
    {:noreply, load_jobs(socket)}
  end

  # --- Private ---

  defp load_entries(socket) do
    case FileExplorer.list(socket.assigns.current_dir) do
      {:ok, entries} ->
        sorted =
          Enum.sort_by(entries, fn e -> {if(e.type == :directory, do: 0, else: 1), e.name} end)

        assign(socket, entries: sorted)

      {:error, _} ->
        assign(socket, entries: [])
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

  # --- Helpers used in template ---

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
end
