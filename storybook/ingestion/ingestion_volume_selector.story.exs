defmodule Storybook.Ingestion.IngestionVolumeSelector do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionVolumeSelector

  def description, do: "BO ingestion chrome — unified volume and data-source toggle."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:volumes, %{"archives" => "/vol/archives", "documents" => "/vol/documents"})
      |> assign(:current_volume, "documents")
      |> assign(:current_provider, "local")
      |> assign(:data_sources, [
        %{id: "google_drive", label: "Google Drive", path: "/bo/ingestion/google_drive"}
      ])

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.volume_selector
        volumes={@volumes}
        current_volume={@current_volume}
        current_provider={@current_provider}
        data_sources={@data_sources}
      />
    </div>
    """
  end
end
