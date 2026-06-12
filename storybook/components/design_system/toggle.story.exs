defmodule Storybook.Components.DesignSystem.Toggle do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Toggle

  def description, do: "BO ingestion chrome — list/grid toggle and item count."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:view_mode, "list")
      |> assign(:entries, [%{name: "a"}, %{name: "b"}])

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.toggle view_mode={@view_mode} entries={@entries} />
    </div>
    """
  end
end
