defmodule Storybook.Components.DesignSystem.TabNav do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.TabNav

  def description, do: "Segmented tab bar for BO master panels (People / Teams pattern)."

  def render(assigns) do
    tabs = [
      %{id: :people, label: "People"},
      %{id: :teams, label: "Teams"}
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <div style="padding: var(--zaq-scale-32); max-width: 28rem;">
      <p style="font-size: 0.65rem; font-family: ui-monospace, monospace; opacity: 0.4; margin-bottom: 1rem;">
        People active
      </p>
      <.tab_nav active_tab={:people} tabs={@tabs} />

      <p style="font-size: 0.65rem; font-family: ui-monospace, monospace; opacity: 0.4; margin: 2rem 0 1rem;">
        Teams active
      </p>
      <.tab_nav active_tab={:teams} tabs={@tabs} />
    </div>
    """
  end
end
