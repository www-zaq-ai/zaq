defmodule Storybook.Ingestion.IngestionFileBrowserHeader do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionFileBrowserHeader
  import ZaqWeb.Components.DesignSystem.Toggle

  def description, do: "BO ingestion chrome — view toggle and file browser actions."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:selected, MapSet.new(["/vol/docs/a.md"]))
      |> assign(:ingest_mode, "async")
      |> assign(:embedding_ready, true)
      |> assign(:view_mode, "list")

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <div class="zaq-ingestion-chrome-row zaq-ingestion-chrome-row--spaced">
        <.toggle
          value={@view_mode}
          event="toggle_view_mode"
          value_param="mode"
          suffix="3 item(s)"
          choices={[
            %{value: "list", icon: "hero-bars-3", title: "List view"},
            %{value: "grid", icon: "hero-squares-2x2", title: "Grid view"}
          ]}
        />
        <.file_browser_header
          selected={@selected}
          ingest_mode={@ingest_mode}
          embedding_ready={@embedding_ready}
        />
      </div>
    </div>
    """
  end
end
