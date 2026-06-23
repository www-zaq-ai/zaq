defmodule Storybook.Ingestion.IngestionFileBrowserHeader do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionFileBrowserHeader

  def description, do: "BO ingestion chrome — file browser toolbar and ingest CTA."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:selected, MapSet.new(["/vol/docs/a.md"]))
      |> assign(:ingest_mode, "async")
      |> assign(:embedding_ready, true)

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.file_browser_header
        selected={@selected}
        ingest_mode={@ingest_mode}
        embedding_ready={@embedding_ready}
      />
    </div>
    """
  end
end
