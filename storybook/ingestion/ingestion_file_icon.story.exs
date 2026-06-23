defmodule Storybook.Ingestion.IngestionFileIcon do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionFileIcon, only: [file_icon: 1]

  def description, do: "Extension-based file icons for ingestion file browser."

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32); display: flex; flex-wrap: wrap; gap: var(--zaq-scale-16); align-items: center;">
      <.file_icon name="a.pdf" />
      <.file_icon name="b.md" />
      <.file_icon name="c.xlsx" />
      <.file_icon name="d.zip" />
    </div>
    """
  end
end
