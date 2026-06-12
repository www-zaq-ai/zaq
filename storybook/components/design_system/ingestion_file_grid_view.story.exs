defmodule Storybook.Components.DesignSystem.IngestionFileGridView do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionFileGridView

  def description, do: "Ingestion file browser — card grid (empty state)."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:entries, [])
      |> assign(:selected, MapSet.new())
      |> assign(:current_dir, ".")
      |> assign(:current_volume, "default")
      |> assign(:ingestion_map, %{})

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.file_grid_view
        entries={@entries}
        selected={@selected}
        current_dir={@current_dir}
        current_volume={@current_volume}
        ingestion_map={@ingestion_map}
      />
    </div>
    """
  end
end
