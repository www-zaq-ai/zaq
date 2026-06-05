defmodule Storybook.Semantic.Colors do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "ZAQ semantic color tokens — surface, border, and text/body aliases mapping foundations palette to roles."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-family-body, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Surface
        </h2>
        <div style="display: grid; grid-template-columns: repeat(5, 1fr); gap: 0.75rem;">
          <.swatch name="surface/base" var="--zaq-surface-color-base" border />
          <.swatch name="surface/raised" var="--zaq-surface-color-raised" border />
          <.swatch name="surface/elevated" var="--zaq-surface-color-elevated" border />
          <.swatch name="surface/accent" var="--zaq-surface-color-accent" border />
          <.swatch name="surface/dark" var="--zaq-surface-color-dark" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Border
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="border/default" var="--zaq-border-color-default" border />
          <.swatch name="border/strong" var="--zaq-border-color-strong" border />
          <.swatch name="border/accent" var="--zaq-border-color-accent" border />
          <.swatch name="border/error" var="--zaq-border-color-error" />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Text
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="text/body/default" var="--zaq-text-color-body-default" />
          <.swatch name="text/body/secondary" var="--zaq-text-color-body-secondary" />
          <.swatch name="text/body/tertiary" var="--zaq-text-color-body-tertiary" />
          <.swatch name="text/body/invert" var="--zaq-text-color-body-invert" border />
        </div>
      </section>
    </div>
    """
  end

  defp swatch(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.4rem;">
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
