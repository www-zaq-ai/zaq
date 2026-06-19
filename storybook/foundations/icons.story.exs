defmodule Storybook.Foundations.Icons do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "All icons available in ZAQ — custom registry (section/nav/provider namespaces) and Heroicons via core_components."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          IconRegistry
        </h2>
        <p style="font-size: 0.75rem; opacity: 0.5; margin-bottom: 1.5rem; font-family: ui-monospace, monospace;">
          &lt;ZaqWeb.Components.IconRegistry.icon namespace="nav" name="dashboard" class="w-5 h-5" /&gt;
        </p>
        <.icon_group namespace="section" icons={["ai", "communication", "accounts", "system"]} />
        <.icon_group
          namespace="nav"
          icons={[
            "dashboard",
            "ai",
            "prompt",
            "ingestion",
            "ontology",
            "knowledge_gap",
            "channels",
            "history",
            "users",
            "people",
            "roles",
            "license",
            "conversations",
            "config"
          ]}
        />
        <.icon_group namespace="provider" icons={["mattermost"]} />
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 0.5rem;">
          Heroicons
        </h2>
        <p style="font-size: 0.75rem; opacity: 0.5; margin-bottom: 1.5rem; font-family: ui-monospace, monospace;">
          &lt;.icon name="hero-x-mark" class="w-5 h-5" /&gt;
        </p>
        <.heroicon_grid icons={[
          "hero-x-mark",
          "hero-check",
          "hero-plus",
          "hero-minus",
          "hero-pencil",
          "hero-trash",
          "hero-eye",
          "hero-eye-slash",
          "hero-arrow-left",
          "hero-arrow-right",
          "hero-arrow-up",
          "hero-arrow-down",
          "hero-chevron-left",
          "hero-chevron-right",
          "hero-chevron-up",
          "hero-chevron-down",
          "hero-magnifying-glass",
          "hero-funnel",
          "hero-bars-3",
          "hero-ellipsis-vertical",
          "hero-information-circle",
          "hero-exclamation-circle",
          "hero-exclamation-triangle",
          "hero-check-circle",
          "hero-bell",
          "hero-cog-6-tooth",
          "hero-user",
          "hero-users",
          "hero-document",
          "hero-folder",
          "hero-paper-clip",
          "hero-link",
          "hero-arrow-up-tray",
          "hero-arrow-down-tray",
          "hero-clipboard",
          "hero-clipboard-document-check"
        ]} />
      </section>
    </div>
    """
  end

  defp icon_group(assigns) do
    ~H"""
    <div style="margin-bottom: 2rem;">
      <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.3; margin-bottom: 1rem;">
        {@namespace}
      </h3>
      <div style="display: flex; flex-wrap: wrap; gap: 1.5rem;">
        <div
          :for={name <- @icons}
          style="display: flex; flex-direction: column; align-items: center; gap: 0.5rem; width: 72px;"
        >
          <div style="width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; background: var(--zaq-color-accent-soft, rgba(3,182,212,0.08)); border-radius: 8px;">
            <ZaqWeb.Components.IconRegistry.icon namespace={@namespace} name={name} class="w-5 h-5" />
          </div>
          <span style="font-family: ui-monospace, monospace; font-size: 0.6rem; opacity: 0.5; text-align: center; word-break: break-word;">
            {name}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp heroicon_grid(assigns) do
    ~H"""
    <div style="display: flex; flex-wrap: wrap; gap: 1.5rem;">
      <div
        :for={name <- @icons}
        style="display: flex; flex-direction: column; align-items: center; gap: 0.5rem; width: 72px;"
      >
        <div style="width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,0.03); border-radius: 8px;">
          <ZaqWeb.CoreComponents.icon name={name} class="w-5 h-5" />
        </div>
        <span style="font-family: ui-monospace, monospace; font-size: 0.6rem; opacity: 0.5; text-align: center; word-break: break-word;">
          {String.replace(name, "hero-", "")}
        </span>
      </div>
    </div>
    """
  end
end
