defmodule ZaqWeb.Live.BO.AI.UrlCrawlerPreviewLive do
  use ZaqWeb, :live_view

  alias ZaqWeb.Live.BO.AI.UrlCrawlerPreview

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    preview = UrlCrawlerPreview.preview!(id)

    {:ok,
     socket
     |> assign(:page_title, "Crawl Preview")
     |> assign(:current_path, "/bo/ingestion")
     |> assign(:preview_data, preview)}
  end

  @impl true
  def handle_event("save_configuration", _params, socket) do
    configuration_id =
      UrlCrawlerPreview.save_target_configuration_id(socket.assigns.preview_data.id)

    {:noreply,
     socket
     |> put_flash(:info, "Preview only: configuration would be saved from this tree preview.")
     |> push_navigate(to: ~p"/bo/ingestion/url_crawler/#{configuration_id}")}
  end
end
