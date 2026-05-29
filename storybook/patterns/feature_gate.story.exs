defmodule Storybook.Patterns.FeatureGate do
  use PhoenixStorybook.Story, :page

  def description, do: "Full-page 'Feature Not Licensed' gate. Use as the sole body content inside bo_layout when a feature flag is disabled."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 700px;">

      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace;">
        &lt;ZaqWeb.Components.BOLayout.feature_gate feature_name="Ontology" /&gt;
      </p>

      <div>
        <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.35; margin-bottom: 0.75rem;">Default (feature name only)</h3>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 8px; padding: 1rem; background: var(--zaq-color-surface, #faf9f7);">
          <ZaqWeb.Components.BOLayout.feature_gate feature_name="Ontology" />
        </div>
      </div>

      <div>
        <h3 style="font-size: 0.65rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; opacity: 0.35; margin-bottom: 0.75rem;">Custom message</h3>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 8px; padding: 1rem; background: var(--zaq-color-surface, #faf9f7);">
          <ZaqWeb.Components.BOLayout.feature_gate
            feature_name="Knowledge Gap"
            message="Upgrade your license to enable knowledge gap analysis."
          />
        </div>
      </div>

    </div>
    """
  end
end
