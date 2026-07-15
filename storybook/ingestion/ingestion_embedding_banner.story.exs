defmodule Storybook.Ingestion.IngestionEmbeddingBanner do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionEmbeddingBanner

  def description, do: "Banner when embedding is not configured (ingestion BO)."

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.ingestion_embedding_banner />
    </div>
    """
  end
end
