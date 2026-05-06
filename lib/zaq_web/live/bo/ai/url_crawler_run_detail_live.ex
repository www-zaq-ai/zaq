defmodule ZaqWeb.Live.BO.AI.UrlCrawlerRunDetailLive do
  use ZaqWeb, :live_view

  alias ZaqWeb.Live.BO.AI.UrlCrawlerPreview

  @tick_ms 900

  @impl true
  def mount(%{"id" => configuration_id, "run_id" => run_id}, _session, socket) do
    configuration = UrlCrawlerPreview.configuration!(configuration_id)
    run = UrlCrawlerPreview.run!(configuration_id, run_id)

    if connected?(socket) and run.status == "running" do
      Process.send_after(self(), :tick_progress, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Run Detail")
     |> assign(:current_path, "/bo/ingestion")
     |> assign(:configuration, configuration)
     |> assign(:run, run)
     |> assign(:expanded_paths, UrlCrawlerPreview.default_expanded_paths(run.approved_page_list))}
  end

  @impl true
  def handle_event("toggle_branch", %{"path" => path}, socket) do
    expanded_paths =
      if MapSet.member?(socket.assigns.expanded_paths, path) do
        MapSet.delete(socket.assigns.expanded_paths, path)
      else
        MapSet.put(socket.assigns.expanded_paths, path)
      end

    {:noreply, assign(socket, :expanded_paths, expanded_paths)}
  end

  @impl true
  def handle_info(:tick_progress, %{assigns: %{run: %{status: "running", progress: progress}}} = socket) when progress < 100 do
    next_progress = min(progress + 8, 100)
    next_status = if next_progress >= 100, do: "done", else: "running"
    last_update = if next_status == "done", do: "Live just now", else: socket.assigns.run.last_update

    run = %{socket.assigns.run | progress: next_progress, status: next_status, last_update: last_update}

    if next_status == "running" do
      Process.send_after(self(), :tick_progress, @tick_ms)
    end

    {:noreply, assign(socket, :run, run)}
  end

  def handle_info(:tick_progress, socket), do: {:noreply, socket}

  def status_classes(status), do: UrlCrawlerPreview.status_classes(status)
  def status_label(status), do: UrlCrawlerPreview.status_label(status)
  def tree_rows(run, expanded_paths), do: UrlCrawlerPreview.tree_rows(run.approved_page_list, expanded_paths)
end
