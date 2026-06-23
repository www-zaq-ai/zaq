defmodule Storybook.Ingestion.IngestionVolumeSelector do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionVolumeSelector

  def description, do: "BO ingestion chrome — document volume toggle row."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:volumes, %{"docs" => "/vol/docs", "raw" => "/vol/raw"})
      |> assign(:current_volume, "docs")

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.volume_selector volumes={@volumes} current_volume={@current_volume} />
    </div>
    """
  end
end
