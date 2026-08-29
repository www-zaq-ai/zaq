defmodule Storybook.Ingestion.IngestionSourceSelector do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionSourceSelector

  def description, do: "BO ingestion chrome — unified data-source scope toggle."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:active_source_id, "disk:1:documents")
      |> assign(:data_sources, [
        %{id: "disk:1:archives", label: "archives", provider: "disk"},
        %{id: "disk:1:documents", label: "documents", provider: "disk"},
        %{id: "google_drive:2:2", label: "Google Drive", provider: "google_drive"}
      ])

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.source_selector
        active_source_id={@active_source_id}
        sources={@data_sources}
      />
    </div>
    """
  end
end
