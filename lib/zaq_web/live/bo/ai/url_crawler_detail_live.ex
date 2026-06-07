defmodule ZaqWeb.Live.BO.AI.UrlCrawlerDetailLive do
  use ZaqWeb, :live_view

  alias ZaqWeb.Live.BO.AI.UrlCrawlerPreview

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    configuration = UrlCrawlerPreview.configuration!(id)
    runs = UrlCrawlerPreview.runs_for_configuration!(id)

    {:ok,
     socket
     |> assign(:page_title, "Crawl Runs")
     |> assign(:current_path, "/bo/ingestion")
     |> assign(:configuration, configuration)
     |> assign(:runs, runs)
     |> assign(:launch_modal_open, false)
     |> assign(:selected_ingestion_strategy, ".md")}
  end

  @impl true
  def handle_event("open_launch_modal", _params, socket) do
    {:noreply, assign(socket, :launch_modal_open, true)}
  end

  def handle_event("close_launch_modal", _params, socket) do
    {:noreply, assign(socket, :launch_modal_open, false)}
  end

  def handle_event("set_ingestion_strategy", %{"strategy" => strategy}, socket) do
    {:noreply, assign(socket, :selected_ingestion_strategy, strategy)}
  end

  def handle_event("launch_run", _params, socket) do
    configuration_id = socket.assigns.configuration.id
    run = UrlCrawlerPreview.latest_run!(configuration_id)

    {:noreply,
     socket
     |> assign(:launch_modal_open, false)
     |> put_flash(
       :info,
       "Preview only: a new run would launch now using #{socket.assigns.selected_ingestion_strategy}."
     )
     |> push_navigate(to: ~p"/bo/ingestion/url_crawler/#{configuration_id}/runs/#{run.id}")}
  end

  def status_classes(status), do: UrlCrawlerPreview.status_classes(status)
  def status_label(status), do: UrlCrawlerPreview.status_label(status)
  def strategy_options, do: UrlCrawlerPreview.strategy_options()
end
