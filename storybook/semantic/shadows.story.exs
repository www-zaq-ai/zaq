defmodule Storybook.Semantic.Shadows do
  use PhoenixStorybook.Story, :page

  def description, do: "Shadow and elevation scale used across ZAQ surfaces."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 2rem;">
          Shadow Scale
        </h2>
        <div style="display: flex; flex-wrap: wrap; gap: 2.5rem; align-items: flex-end;">
          <.shadow_swatch label="none" usage="Flat / disabled" shadow="none" />
          <.shadow_swatch
            label="xs"
            usage="Chips, badges, subtle cards"
            shadow="0 1px 2px rgba(0,0,0,0.06)"
          />
          <.shadow_swatch
            label="sm"
            usage="Cards, inputs on focus"
            shadow="0 2px 6px rgba(0,0,0,0.08)"
          />
          <.shadow_swatch label="md" usage="Dropdowns, popovers" shadow="0 4px 16px rgba(0,0,0,0.10)" />
          <.shadow_swatch label="lg" usage="Modals, drawers" shadow="0 8px 32px rgba(0,0,0,0.14)" />
          <.shadow_swatch
            label="xl"
            usage="Tooltips, floating panels"
            shadow="0 14px 30px rgba(15,23,42,0.22)"
          />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Elevation Reference
        </h2>
        <div style="display: flex; flex-direction: column; gap: 0; max-width: 480px;">
          <.elevation_row level="0 — Base" z="auto" usage="Page canvas, content area" />
          <.elevation_row level="10 — Raised" z="10" usage="Sticky header, side panel" />
          <.elevation_row level="100 — Overlay" z="100" usage="Dropdowns, inline popovers" />
          <.elevation_row level="500 — Dialog" z="500" usage="Modals, drawers" />
          <.elevation_row level="1200 — Top" z="1200" usage="Tooltips (zaq-chart-tooltip)" />
        </div>
      </section>
    </div>
    """
  end

  defp shadow_swatch(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; align-items: center; gap: 0.75rem;">
      <div style={"width: 80px; height: 80px; background: var(--zaq-color-surface, #faf9f7); border-radius: 10px; box-shadow: #{@shadow}; border: 1px solid rgba(0,0,0,0.04);"}>
      </div>
      <div style="text-align: center;">
        <div style="font-size: 0.7rem; font-weight: 600; opacity: 0.7;">{@label}</div>
        <div style="font-size: 0.65rem; opacity: 0.4; margin-top: 0.15rem;">{@usage}</div>
      </div>
    </div>
    """
  end

  defp elevation_row(assigns) do
    ~H"""
    <div style="display: grid; grid-template-columns: 160px 60px 1fr; gap: 1rem; padding: 0.75rem 0; border-bottom: 1px solid rgba(0,0,0,0.05); align-items: center;">
      <span style="font-size: 0.75rem; font-weight: 500; opacity: 0.75;">{@level}</span>
      <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.4;">
        z-{@z}
      </span>
      <span style="font-size: 0.7rem; opacity: 0.5;">{@usage}</span>
    </div>
    """
  end
end
