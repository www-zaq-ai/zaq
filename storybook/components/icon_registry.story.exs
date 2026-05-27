defmodule Storybook.Components.IconRegistry do
  use PhoenixStorybook.Story, :page

  def description, do: "All icons available via ZaqWeb.Components.IconRegistry. Grouped by namespace."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">

      <.icon_group namespace="section" icons={["ai", "communication", "accounts", "system"]} />
      <.icon_group namespace="nav"     icons={["dashboard", "ai", "prompt", "ingestion", "ontology", "knowledge_gap", "channels", "history", "users", "people", "roles", "license", "conversations", "config"]} />
      <.icon_group namespace="provider" icons={["mattermost"]} />

    </div>
    """
  end

  defp icon_group(assigns) do
    ~H"""
    <section>
      <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;"><%= @namespace %></h2>
      <div style="display: flex; flex-wrap: wrap; gap: 1.5rem;">
        <div :for={name <- @icons} style="display: flex; flex-direction: column; align-items: center; gap: 0.5rem; width: 72px;">
          <div style="width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; background: var(--zaq-color-accent-soft, rgba(3,182,212,0.08)); border-radius: 8px;">
            <ZaqWeb.Components.IconRegistry.icon namespace={@namespace} name={name} class="w-5 h-5" />
          </div>
          <span style="font-family: ui-monospace, monospace; font-size: 0.6rem; opacity: 0.5; text-align: center; word-break: break-word;"><%= name %></span>
        </div>
      </div>
    </section>
    """
  end
end
