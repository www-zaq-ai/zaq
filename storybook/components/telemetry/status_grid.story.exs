defmodule Storybook.Components.Telemetry.StatusGrid do
  use PhoenixStorybook.Story, :page

  def description, do: "status_grid — grid of status indicators for multi-service health dashboards. progress_countdown — progress bar with time countdown for running operations."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 700px;">

      <p style="font-size: 0.8rem; background: rgba(255,200,60,0.1); border: 1px solid rgba(255,180,0,0.3); border-radius: 6px; padding: 0.75rem 1rem; line-height: 1.6;">
        <strong>Note:</strong> These components receive pre-computed <code style="font-family: ui-monospace, monospace;">chart</code> data maps from the LiveView. Live previews are not available in Storybook — see usage examples below.
      </p>

      <section>
        <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">status_grid</h2>
        <p style="font-size: 0.8rem; opacity: 0.6; margin-bottom: 1rem; line-height: 1.5;">Grid of coloured status cells — useful for displaying health checks across multiple nodes or services over time.</p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Components.BOTelemetryComponents.status_grid
  chart=&#123;&#64;grid_data&#125;
  id="node-health-grid"
  title="Node health"
/&gt;</code></pre>
      </section>

      <section>
        <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">progress_countdown</h2>
        <p style="font-size: 0.8rem; opacity: 0.6; margin-bottom: 1rem; line-height: 1.5;">Progress bar with a numerical countdown — used for ingestion jobs, scheduled tasks, and timed operations.</p>
        <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.75rem; overflow-x: auto;"><code>&lt;ZaqWeb.Components.BOTelemetryComponents.progress_countdown
  chart=&#123;&#64;progress_data&#125;
  id="ingestion-progress"
  label="Documents indexed"
/&gt;</code></pre>
      </section>

    </div>
    """
  end
end
