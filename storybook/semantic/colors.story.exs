defmodule Storybook.Semantic.Colors do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "ZAQ semantic color tokens — surface, border, and text/body aliases mapping foundations palette to roles."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-family-body, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; width: 100%; box-sizing: border-box;">
      <section style="width: 100%;">
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Surface
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.75rem; width: 100%;">
          <.swatch name="surface/base" var="--zaq-surface-color-base" border />
          <.swatch name="surface/raised" var="--zaq-surface-color-raised" border />
          <.swatch name="surface/elevated" var="--zaq-surface-color-elevated" border />
          <.swatch name="surface/accent" var="--zaq-surface-color-accent" border />
        </div>
      </section>

      <section style="width: 100%;">
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Border
        </h2>
        <div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.75rem; width: 100%;">
          <.swatch name="border/default" var="--zaq-border-color-default" border />
          <.swatch name="border/strong" var="--zaq-border-color-strong" border />
          <.swatch name="border/accent" var="--zaq-border-color-accent" border />
        </div>
      </section>

      <section style="width: 100%;">
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Text
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.75rem; width: 100%;">
          <.swatch name="text/body/default" var="--zaq-text-color-body-default" />
          <.swatch name="text/body/secondary" var="--zaq-text-color-body-secondary" />
          <.swatch name="text/body/tertiary" var="--zaq-text-color-body-tertiary" />
          <.swatch name="text/body/invert" var="--zaq-text-color-body-invert" border />
        </div>
      </section>

      <section style="width: 100%;">
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          System
        </h2>
        <div style="display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 0.75rem; width: 100%;">
          <.swatch name="border/danger" var="--zaq-border-color-danger" border />
          <.swatch name="surface/danger" var="--zaq-surface-color-danger" border />
          <.swatch name="border/success" var="--zaq-border-color-success" border />
          <.swatch name="surface/success" var="--zaq-surface-color-success" border />
          <.swatch name="border/warning" var="--zaq-border-color-warning" border />
          <.swatch name="surface/warning" var="--zaq-surface-color-warning" border />
        </div>
      </section>
    </div>
    """
  end

  defp swatch(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.4rem; min-width: 0;">
      <div style={"height: 48px; border-radius: 8px; background: var(#{@var}); #{if Map.get(assigns, :border), do: "border: 1px solid rgba(0,0,0,0.08);"}"}>
      </div>
      <span style="font-size: 0.7rem; opacity: 0.6; font-family: ui-monospace, monospace;">
        {@name}
      </span>
      <span style="font-size: 0.65rem; opacity: 0.35; font-family: ui-monospace, monospace;">
        {@var}
      </span>
    </div>
    """
  end
end
