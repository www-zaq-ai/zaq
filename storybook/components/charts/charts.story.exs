defmodule Storybook.Components.Charts.Charts do
  use PhoenixStorybook.Story, :page

  def description,
    do:
      "Chart components — time_series, bar, donut, gauge, and radar. These require the ChartTooltipHook JS hook and receive pre-computed chart data maps from the LiveView."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, monospace); padding: 2rem; display: flex; flex-direction: column; gap: 3rem; max-width: 800px;">
      <p style="font-size: 0.8rem; background: rgba(255,200,60,0.1); border: 1px solid rgba(255,180,0,0.3); border-radius: 6px; padding: 0.75rem 1rem; line-height: 1.6;">
        <strong>Note:</strong>
        Chart components require the
        <code style="font-family: ui-monospace, monospace;">ChartTooltipHook</code>
        JS hook and render SVG via the
        <code style="font-family: ui-monospace, monospace;">chart</code>
        data map computed server-side. Live previews are not available in Storybook — see usage examples below.
      </p>

      <.chart_doc
        name="time_series_chart"
        module="ZaqWeb.Components.BOTelemetryComponents"
        description="Line or area chart for time-series data — queries per hour, response times, etc."
        attrs={[
          {"chart", "map (required)", "Pre-computed chart data with :points, :labels, :min, :max"},
          {"id", "string", "DOM id for hook targeting"},
          {"title", "string", "Chart title"},
          {"secondary_color", "string", "Accent colour for secondary series"},
          {"width", "integer", "SVG width in px"},
          {"height", "integer", "SVG height in px"}
        ]}
      />

      <.chart_doc
        name="bar_chart"
        module="ZaqWeb.Components.BOTelemetryComponents"
        description="Vertical bar chart for categorical comparisons."
        attrs={[
          {"chart", "map (required)", "Pre-computed chart data with :bars and :labels"},
          {"id", "string", "DOM id"},
          {"title", "string", "Chart title"}
        ]}
      />

      <.chart_doc
        name="donut_chart"
        module="ZaqWeb.Components.BOTelemetryComponents"
        description="Donut / pie chart for part-to-whole relationships."
        attrs={[
          {"chart", "map (required)", "Pre-computed chart data with :slices"},
          {"id", "string", "DOM id"},
          {"title", "string", "Chart title"}
        ]}
      />

      <.chart_doc
        name="gauge_chart"
        module="ZaqWeb.Components.BOTelemetryComponents"
        description="Single-value gauge for bounded metrics (e.g. confidence score 0–1)."
        attrs={[
          {"chart", "map (required)", "Pre-computed chart data with :value, :min, :max"},
          {"id", "string", "DOM id"},
          {"label", "string", "Gauge label"}
        ]}
      />

      <.chart_doc
        name="radar_chart"
        module="ZaqWeb.Components.BOTelemetryComponents"
        description="Radar / spider chart for multi-dimensional comparisons."
        attrs={[
          {"chart", "map (required)", "Pre-computed chart data with :axes and :series"},
          {"id", "string", "DOM id"},
          {"title", "string", "Chart title"},
          {"size", "integer", "SVG size in px (square)"}
        ]}
      />
    </div>
    """
  end

  defp chart_doc(assigns) do
    ~H"""
    <section>
      <h2 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.25rem;">{@name}</h2>
      <p style="font-size: 0.8rem; opacity: 0.6; margin-bottom: 1rem; line-height: 1.5;">
        {@description}
      </p>
      <pre style="background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 6px; padding: 0.75rem 1rem; font-size: 0.72rem; overflow-x: auto; margin-bottom: 0.75rem;"><code>&lt;<%= @module %>.<%= @name %> chart=&#123;&#64;chart_data&#125; id="my-chart" /&gt;</code></pre>
      <table style="width: 100%; font-size: 0.75rem; border-collapse: collapse;">
        <thead>
          <tr style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);">
            <th style="text-align: left; padding: 0.4rem 0.6rem; opacity: 0.4;">Attr</th>
            <th style="text-align: left; padding: 0.4rem 0.6rem; opacity: 0.4;">Type</th>
            <th style="text-align: left; padding: 0.4rem 0.6rem; opacity: 0.4;">Notes</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{name, type, note} <- @attrs}
            style="border-bottom: 1px solid var(--zaq-color-surface-border, #e8e6e1);"
          >
            <td style="padding: 0.4rem 0.6rem; font-family: ui-monospace, monospace;">{name}</td>
            <td style="padding: 0.4rem 0.6rem; opacity: 0.5;">{type}</td>
            <td style="padding: 0.4rem 0.6rem; opacity: 0.5;">{note}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end
