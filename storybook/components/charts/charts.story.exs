defmodule Storybook.Components.Charts.Charts do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias ZaqWeb.Components.BOTelemetryComponents, as: Charts

  def description,
    do:
      "Chart components — time_series, bar, donut, gauge, and radar. Static samples use `DashboardChart.new/1` (same shape as production). Tooltips work in Storybook via `ChartTooltip` hook."

  def render(assigns) do
    ~H"""
    <div
      class="zaq-text-body"
      style="padding: var(--zaq-scale-32); display: flex; flex-direction: column; gap: var(--zaq-scale-48); max-width: 72rem;"
    >
      <p
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-secondary); max-width: 42rem; line-height: 1.6;"
      >
        In the app, <code style="font-family: ui-monospace, monospace;">chart</code>
        maps are computed server-side in LiveViews. Below are static samples built with
        <code style="font-family: ui-monospace, monospace;">DashboardChart.new/1</code>
        — the same contract production uses. Hover donut and radar segments for tooltips.
      </p>

      <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(20rem, 1fr)); gap: var(--zaq-scale-24);">
        <Charts.time_series_chart
          id="sb-chart-time-series"
          chart={time_series_sample()}
        />
        <Charts.bar_chart id="sb-chart-bar" chart={bar_sample()} />
        <Charts.donut_chart id="sb-chart-donut" chart={donut_sample()} />
        <Charts.gauge_chart id="sb-chart-gauge" chart={gauge_sample()} />
        <Charts.radar_chart id="sb-chart-radar" chart={radar_sample()} />
      </div>

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

  defp time_series_sample do
    DashboardChart.new(%{
      id: "sb-chart-time-series",
      kind: :time_series,
      title: "Queries per hour",
      labels: ["09:00", "10:00", "11:00", "12:00", "13:00"],
      series: [%{key: "primary", name: "Queries", values: [42, 58, 51, 73, 68]}],
      summary: %{benchmarks: %{"primary" => [38, 45, 49, 52, 55]}},
      meta: %{}
    })
  end

  defp bar_sample do
    DashboardChart.new(%{
      id: "sb-chart-bar",
      kind: :bar,
      title: "Top sources",
      summary: %{
        bars: [
          %{label: "Mattermost", value: 48},
          %{label: "API", value: 32},
          %{label: "Email", value: 19}
        ]
      },
      meta: %{}
    })
  end

  defp donut_sample do
    DashboardChart.new(%{
      id: "sb-chart-donut",
      kind: :donut,
      title: "Resolution mix",
      summary: %{
        segments: [
          %{label: "Resolved", value: 72},
          %{label: "Pending", value: 18},
          %{label: "Escalated", value: 10}
        ]
      },
      meta: %{}
    })
  end

  defp gauge_sample do
    DashboardChart.new(%{
      id: "sb-chart-gauge",
      kind: :gauge,
      title: "Confidence score",
      summary: %{value: 73.2, benchmark_value: 58.4, min: 0.0, max: 100.0},
      meta: %{}
    })
  end

  defp radar_sample do
    DashboardChart.new(%{
      id: "sb-chart-radar",
      kind: :radar,
      title: "Retrieval quality",
      summary: %{
        axes: [
          %{label: "Latency", value: 72},
          %{label: "Recall", value: 84},
          %{label: "Precision", value: 78},
          %{label: "Coverage", value: 65}
        ],
        benchmark_axes: [
          %{label: "Latency", value: 54},
          %{label: "Recall", value: 61},
          %{label: "Precision", value: 58},
          %{label: "Coverage", value: 52}
        ]
      },
      meta: %{}
    })
  end

  attr :name, :string, required: true
  attr :module, :string, required: true
  attr :description, :string, required: true
  attr :attrs, :list, required: true

  defp chart_doc(assigns) do
    ~H"""
    <section>
      <h2 class="zaq-text-body-sm" style="font-weight: 600; margin-bottom: var(--zaq-scale-4);">
        {@name}
      </h2>
      <p
        class="zaq-text-caption"
        style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-16); line-height: 1.5;"
      >
        {@description}
      </p>
      <pre style="background: var(--zaq-surface-color-raised); border: 1px solid var(--zaq-border-color-default); border-radius: var(--zaq-scale-8); padding: var(--zaq-scale-12) var(--zaq-scale-16); font-size: 0.72rem; overflow-x: auto; margin-bottom: var(--zaq-scale-12);"><code>&lt;<%= @module %>.<%= @name %> chart=&#123;&#64;chart_data&#125; id="my-chart" /&gt;</code></pre>
      <table style="width: 100%; font-size: 0.75rem; border-collapse: collapse;">
        <thead>
          <tr style="border-bottom: 1px solid var(--zaq-border-color-default);">
            <th
              class="zaq-text-caption"
              style="text-align: left; padding: var(--zaq-scale-8) var(--zaq-scale-12); color: var(--zaq-text-color-body-tertiary);"
            >
              Attr
            </th>
            <th
              class="zaq-text-caption"
              style="text-align: left; padding: var(--zaq-scale-8) var(--zaq-scale-12); color: var(--zaq-text-color-body-tertiary);"
            >
              Type
            </th>
            <th
              class="zaq-text-caption"
              style="text-align: left; padding: var(--zaq-scale-8) var(--zaq-scale-12); color: var(--zaq-text-color-body-tertiary);"
            >
              Notes
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{name, type, note} <- @attrs}
            style="border-bottom: 1px solid var(--zaq-border-color-default);"
          >
            <td style="padding: var(--zaq-scale-8) var(--zaq-scale-12); font-family: ui-monospace, monospace;">
              {name}
            </td>
            <td style="padding: var(--zaq-scale-8) var(--zaq-scale-12); color: var(--zaq-text-color-body-tertiary);">
              {type}
            </td>
            <td style="padding: var(--zaq-scale-8) var(--zaq-scale-12); color: var(--zaq-text-color-body-tertiary);">
              {note}
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end
