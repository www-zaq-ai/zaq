defmodule Storybook.Components.DesignSystem.Breadcrumb do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Breadcrumb

  def description, do: "BO ingestion chrome — path breadcrumbs and back control."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:current_dir, "docs/sub")
      |> assign(:breadcrumbs, [%{name: "docs", path: "docs"}, %{name: "sub", path: "docs/sub"}])

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.breadcrumb breadcrumbs={@breadcrumbs} current_dir={@current_dir} />
    </div>
    """
  end
end
