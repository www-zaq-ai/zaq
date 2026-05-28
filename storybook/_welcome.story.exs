defmodule Storybook.Welcome do
  use PhoenixStorybook.Story, :page

  def description, do: "ZAQ Design System — welcome page"

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 3rem 2rem; max-width: 680px; display: flex; flex-direction: column; gap: 2.5rem;">
      <div style="display: flex; flex-direction: column; gap: 0.75rem;">
        <div style="display: flex; align-items: center; gap: 0.75rem;">
          <div style="width: 10px; height: 10px; border-radius: 999px; background: var(--zaq-color-accent, #03b6d4);">
          </div>
          <span style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; color: var(--zaq-color-accent, #03b6d4);">
            ZAQ Design System
          </span>
        </div>
        <h1 style="font-size: 2rem; font-weight: 700; color: var(--zaq-color-ink, #2c3a50); line-height: 1.2; margin: 0;">
          One source of truth for design and code.
        </h1>
        <p style="font-size: 0.95rem; line-height: 1.7; color: var(--zaq-color-ink-soft, #5c5a55); margin: 0;">
          This Storybook documents every visual building block of ZAQ — from raw design tokens to fully assembled components. What you see here is rendered from the real application code, so it always reflects exactly what ships.
        </p>
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
        <.section_card
          label="Foundation"
          description="Raw design tokens — color palette, typography, spacing, and scale. The primitives everything else is built from."
        />
        <.section_card
          label="Semantics"
          description="Role-based tokens — how raw values map to purpose: colors by role, border radii, and shadow elevation."
        />
        <.section_card
          label="Components"
          description="Modals, selects, icons, layouts — active components used across the back office and chat interfaces."
        />
        <.section_card
          label="Layouts"
          description="Full-page shell components — BO layout, sidebar navigation, header, and sub-components."
        />
        <.section_card
          label="Legacy UI"
          description="Components that predate the current design system. Being reviewed for migration or replacement."
        />
      </div>

      <div style="border-top: 1px solid var(--zaq-color-surface-border, #e8e6e1); padding-top: 1.5rem; display: flex; flex-direction: column; gap: 0.5rem;">
        <p style="font-size: 0.8rem; color: var(--zaq-color-muted, #b8b5ae); margin: 0; line-height: 1.6;">
          Changes to a component in
          <code style="font-family: ui-monospace, monospace; font-size: 0.75em; background: rgba(0,0,0,0.04); padding: 0.1em 0.35em; border-radius: 3px;">
            lib/zaq_web/components/
          </code>
          are reflected here automatically on the next page load — no rebuild needed.
        </p>
        <p style="font-size: 0.8rem; color: var(--zaq-color-muted, #b8b5ae); margin: 0; line-height: 1.6;">
          To add a new story, create a
          <code style="font-family: ui-monospace, monospace; font-size: 0.75em; background: rgba(0,0,0,0.04); padding: 0.1em 0.35em; border-radius: 3px;">
            .story.exs
          </code>
          file in the relevant
          <code style="font-family: ui-monospace, monospace; font-size: 0.75em; background: rgba(0,0,0,0.04); padding: 0.1em 0.35em; border-radius: 3px;">
            storybook/
          </code>
          folder and follow the patterns in any existing story.
        </p>
      </div>
    </div>
    """
  end

  defp section_card(assigns) do
    ~H"""
    <div style="padding: 1.25rem; border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 10px; display: flex; flex-direction: column; gap: 0.4rem; background: var(--zaq-color-surface, #faf9f7);">
      <span style="font-size: 0.75rem; font-weight: 600; color: var(--zaq-color-ink, #2c3a50);">
        {@label}
      </span>
      <span style="font-size: 0.78rem; color: var(--zaq-color-ink-soft, #5c5a55); line-height: 1.55;">
        {@description}
      </span>
    </div>
    """
  end
end
