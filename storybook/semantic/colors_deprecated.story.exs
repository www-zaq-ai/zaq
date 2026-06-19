defmodule Storybook.Semantic.ColorsDeprecated do
  use PhoenixStorybook.Story, :page

  def description,
    do: "Deprecated semantic color tokens — superseded by the foundations-based token system."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">
      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          ZAQ Semantic
        </h2>
        <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.75rem;">
          <.swatch name="accent" var="--zaq-color-accent" />
          <.swatch name="accent-hover" var="--zaq-color-accent-hover" />
          <.swatch name="accent-soft" var="--zaq-color-accent-soft" border />
          <.swatch name="ink" var="--zaq-color-ink" />
          <.swatch name="ink-soft" var="--zaq-color-ink-soft" />
          <.swatch name="muted" var="--zaq-color-muted" />
          <.swatch name="disabled" var="--zaq-color-disabled" />
          <.swatch name="surface" var="--zaq-color-surface" border />
          <.swatch name="surface-border" var="--zaq-color-surface-border" border />
          <.swatch name="surface-divider" var="--zaq-color-surface-divider" border />
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">
          Ontology Nodes
        </h2>
        <div style="display: flex; flex-direction: column; gap: 1rem;">
          <.ontology_row entity="business" />
          <.ontology_row entity="division" />
          <.ontology_row entity="department" />
          <.ontology_row entity="team" />
          <.ontology_row entity="person" />
          <.ontology_row entity="domain" />
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

  defp ontology_row(assigns) do
    ~H"""
    <div style="display: grid; grid-template-columns: 120px repeat(5, 1fr); gap: 0.5rem; align-items: center;">
      <span style="font-size: 0.75rem; font-weight: 500; text-transform: capitalize; opacity: 0.7;">
        {@entity}
      </span>
      <.swatch name="accent" var={"--zaq-ontology-#{@entity}-accent"} />
      <.swatch name="bg" var={"--zaq-ontology-#{@entity}-bg"} border />
      <.swatch name="border" var={"--zaq-ontology-#{@entity}-border"} border />
      <.swatch name="stroke" var={"--zaq-ontology-#{@entity}-stroke"} border />
      <.swatch name="glow" var={"--zaq-ontology-#{@entity}-glow"} border />
    </div>
    """
  end
end
