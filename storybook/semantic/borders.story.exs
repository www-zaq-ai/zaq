defmodule Storybook.Semantic.Borders do
  use PhoenixStorybook.Story, :page

  def description, do: "Border radius tokens and border width from the ZAQ design system."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Border Radius
        </h2>
        <div style="display: flex; flex-wrap: wrap; gap: 2rem; align-items: flex-end;">
          <.radius_swatch label="4px — field" radius="4px" token="--radius-field" />
          <.radius_swatch label="4px — selector" radius="4px" token="--radius-selector" />
          <.radius_swatch label="8px — box" radius="8px" token="--radius-box" />
          <.radius_swatch label="12px" radius="12px" token="scale-12" />
          <.radius_swatch label="16px" radius="16px" token="scale-16" />
          <.radius_swatch label="999px — pill" radius="999px" token="--scale-999" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1.5rem;">
          Border Width
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1rem; max-width: 400px;">
          <.border_swatch label="1px — default dividers" width="1px" />
          <.border_swatch label="1.5px — daisyUI --border" width="1.5px" />
          <.border_swatch label="2px — emphasis" width="2px" />
        </div>
      </section>
    </div>
    """
  end

  defp radius_swatch(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; align-items: center; gap: 0.5rem;">
      <div style={"width: 64px; height: 64px; background: var(--zaq-color-accent-soft, rgba(3,182,212,0.1)); border: 1.5px solid var(--zaq-color-accent, #03b6d4); border-radius: #{@radius};"}>
      </div>
      <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.5; text-align: center;">
        {@label}
      </span>
      <span style="font-family: ui-monospace, monospace; font-size: 0.6rem; opacity: 0.3; text-align: center;">
        {@token}
      </span>
    </div>
    """
  end

  defp border_swatch(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.3rem;">
      <div style={"height: 0; border-top: #{@width} solid var(--zaq-color-ink, #2c3a50); width: 100%;"}>
      </div>
      <span style="font-family: ui-monospace, monospace; font-size: 0.65rem; opacity: 0.5;">
        {@label}
      </span>
    </div>
    """
  end
end
