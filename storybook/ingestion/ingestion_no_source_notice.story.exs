defmodule Storybook.Ingestion.IngestionNoSourceNotice do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionNoSourceNotice

  def description, do: "Notice when no data source is enabled (ingestion BO)."

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.ingestion_no_source_notice />
    </div>
    """
  end
end
