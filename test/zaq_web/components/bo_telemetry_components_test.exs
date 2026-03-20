defmodule ZaqWeb.Components.BOTelemetryComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}
  alias Zaq.Engine.Telemetry.Contracts.Payloads.ScalarPayload
  alias ZaqWeb.Components.BOTelemetryComponents

  test "metric_card/1 renders label, value, and id" do
    html =
      render_component(&BOTelemetryComponents.metric_card/1,
        id: "metric-users",
        label: "Active users",
        value: 12_450,
        trend: 4.2,
        hint: "Last 24h"
      )

    assert html =~ "id=\"metric-users\""
    assert html =~ "Active users"
    assert html =~ "12,450"
    assert html =~ "+4.2%"
    assert html =~ "Last 24h"
  end

  test "metric_card/1 renders display metadata but not runtime metadata" do
    html =
      render_component(&BOTelemetryComponents.metric_card/1,
        id: "metric-runtime-separation",
        card: %ScalarPayload{
          id: "metric-runtime-separation",
          label: "API calls",
          value: 120,
          display: %DisplayMeta{range: "30d", hint: "scope: critical"},
          runtime: %RuntimeMeta{href: "/bo/hidden-runtime"}
        }
      )

    assert html =~ "range: 30d"
    assert html =~ "scope: critical"
    refute html =~ "/bo/hidden-runtime"
  end

  test "time_series_chart/1 renders representative data and id" do
    html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        id: "chart-traffic",
        chart:
          DashboardChart.new(%{
            id: "chart-traffic",
            kind: :time_series,
            title: "Traffic",
            labels: ["T1", "T2", "T3", "T4", "T5"],
            series: [%{key: "primary", name: "Primary", values: [8, 13, 11, 17, 15]}],
            summary: %{benchmarks: %{}},
            meta: %{}
          })
      )

    assert html =~ "id=\"chart-traffic\""
    assert html =~ "phx-hook=\"ChartTooltip\""
    assert html =~ "Traffic"
    assert html =~ "<svg"
    assert html =~ "polyline"
    assert html =~ "data-tip-value="
    assert html =~ "data-line-x-axis-label=\"T1\""
  end

  test "time_series_chart/1 renders benchmark lane when provided" do
    html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        id: "chart-traffic-benchmark",
        chart:
          DashboardChart.new(%{
            id: "chart-traffic-benchmark",
            kind: :time_series,
            title: "Traffic",
            labels: ["Mon", "Tue", "Wed"],
            series: [%{key: "primary", name: "Primary", values: [120, 132, 128]}],
            summary: %{benchmarks: %{"primary" => [98, 104, 108]}},
            meta: %{}
          })
      )

    assert html =~ "data-time-series-lane=\"benchmark\""
    assert html =~ "Mon benchmark"
  end

  test "bar_chart/1 renders bars with id" do
    html =
      render_component(&BOTelemetryComponents.bar_chart/1,
        id: "chart-bars",
        chart:
          DashboardChart.new(%{
            id: "chart-bars",
            kind: :bar,
            title: "Sources",
            summary: %{bars: [%{label: "Mattermost", value: 48}, %{label: "API", value: 32}]},
            meta: %{}
          })
      )

    assert html =~ "id=\"chart-bars\""
    assert html =~ "Mattermost"
    assert html =~ "API"
    assert html =~ "width:"
  end

  test "donut_chart/1 renders segments and id" do
    html =
      render_component(&BOTelemetryComponents.donut_chart/1,
        id: "chart-donut",
        chart:
          DashboardChart.new(%{
            id: "chart-donut",
            kind: :donut,
            title: "Resolution",
            summary: %{
              segments: [%{label: "Resolved", value: 72}, %{label: "Pending", value: 28}]
            },
            meta: %{}
          })
      )

    assert html =~ "id=\"chart-donut\""
    assert html =~ "Resolved"
    assert html =~ "Pending"
    assert html =~ "data-tip-value="
    assert html =~ "72%"
  end

  test "gauge_chart/1 renders gauge value and id" do
    html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-load",
        chart:
          DashboardChart.new(%{
            id: "gauge-load",
            kind: :gauge,
            title: "Load",
            summary: %{value: 67.5, min: 0.0, max: 100.0},
            meta: %{}
          })
      )

    assert html =~ "id=\"gauge-load\""
    assert html =~ "Load"
    assert html =~ "67.5"
    assert html =~ "0 - 100"
    assert html =~ "data-pointer-x="
    assert html =~ "data-gauge-ratio="
  end

  test "gauge_chart/1 progresses left to right as values increase" do
    min_html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-min",
        chart:
          DashboardChart.new(%{
            id: "gauge-min",
            kind: :gauge,
            title: "Load",
            summary: %{value: 0.0, min: 0.0, max: 100.0},
            meta: %{}
          })
      )

    mid_html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-mid",
        chart:
          DashboardChart.new(%{
            id: "gauge-mid",
            kind: :gauge,
            title: "Load",
            summary: %{value: 50.0, min: 0.0, max: 100.0},
            meta: %{}
          })
      )

    max_html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-max",
        chart:
          DashboardChart.new(%{
            id: "gauge-max",
            kind: :gauge,
            title: "Load",
            summary: %{value: 100.0, min: 0.0, max: 100.0},
            meta: %{}
          })
      )

    min_x = extract_data_number(min_html, "data-pointer-x")
    mid_x = extract_data_number(mid_html, "data-pointer-x")
    max_x = extract_data_number(max_html, "data-pointer-x")

    min_y = extract_data_number(min_html, "data-pointer-y")
    mid_y = extract_data_number(mid_html, "data-pointer-y")
    max_y = extract_data_number(max_html, "data-pointer-y")

    assert min_x < mid_x
    assert mid_x < max_x

    # 50% should be at the top apex of the gauge, not the lower half.
    assert mid_y < min_y
    assert mid_y < max_y
  end

  test "gauge_chart/1 points to upper-right for high values" do
    html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-high",
        chart:
          DashboardChart.new(%{
            id: "gauge-high",
            kind: :gauge,
            title: "Load",
            summary: %{value: 73.2, min: 0.0, max: 100.0},
            meta: %{}
          })
      )

    pointer_x = extract_data_number(html, "data-pointer-x")
    pointer_y = extract_data_number(html, "data-pointer-y")

    assert pointer_x > 110.0
    assert pointer_y < 110.0
  end

  test "gauge_chart/1 renders benchmark pointer and value" do
    html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-with-benchmark",
        chart:
          DashboardChart.new(%{
            id: "gauge-with-benchmark",
            kind: :gauge,
            title: "Load",
            summary: %{value: 73.2, benchmark_value: 58.4, min: 0.0, max: 100.0},
            meta: %{}
          })
      )

    assert html =~ "data-gauge-pointer=\"benchmark\""
    assert html =~ "benchmark 58.4"
  end

  test "status_grid/1 renders statuses and id" do
    html =
      render_component(&BOTelemetryComponents.status_grid/1,
        id: "status-grid",
        chart:
          DashboardChart.new(%{
            id: "status-grid",
            kind: :status_grid,
            title: "Services",
            summary: %{
              items: [
                %{label: "Agent", status: :ok, detail: "Healthy"},
                %{label: "Ingestion", status: :warn, detail: "Delayed"}
              ]
            },
            meta: %{}
          })
      )

    assert html =~ "id=\"status-grid\""
    assert html =~ "Agent"
    assert html =~ "Ingestion"
    assert html =~ "Healthy"
    assert html =~ "Delayed"
  end

  test "progress_countdown/1 renders progress and id" do
    html =
      render_component(&BOTelemetryComponents.progress_countdown/1,
        id: "progress-sync",
        chart:
          DashboardChart.new(%{
            id: "progress-sync",
            kind: :progress,
            title: "Sync",
            summary: %{total: 120, remaining: 30},
            meta: %{}
          })
      )

    assert html =~ "id=\"progress-sync\""
    assert html =~ "Sync"
    assert html =~ "75%"
    assert html =~ "remaining of 120"
  end

  test "radar_chart/1 renders polygon and id" do
    html =
      render_component(&BOTelemetryComponents.radar_chart/1,
        id: "radar-quality",
        chart:
          DashboardChart.new(%{
            id: "radar-quality",
            kind: :radar,
            title: "Quality",
            summary: %{
              axes: [
                %{label: "Latency", value: 72},
                %{label: "Recall", value: 84},
                %{label: "Precision", value: 78},
                %{label: "Coverage", value: 65}
              ]
            },
            meta: %{}
          })
      )

    assert html =~ "id=\"radar-quality\""
    assert html =~ "phx-hook=\"ChartTooltip\""
    assert html =~ "Quality"
    assert html =~ "Latency"
    assert html =~ "polygon"
    assert html =~ "data-tip-value="
    assert html =~ "data-radar-color="
  end

  test "radar_chart/1 renders benchmark lane when provided" do
    html =
      render_component(&BOTelemetryComponents.radar_chart/1,
        id: "radar-benchmark",
        chart:
          DashboardChart.new(%{
            id: "radar-benchmark",
            kind: :radar,
            title: "Quality",
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
      )

    assert html =~ "data-radar-series=\"benchmark\""
    assert html =~ "Benchmark lane"
  end

  test "chart components handle empty datasets" do
    line_html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        id: "line-empty",
        chart:
          DashboardChart.new(%{
            id: "line-empty",
            kind: :time_series,
            title: "Line",
            labels: [],
            series: [],
            summary: %{benchmarks: %{}},
            meta: %{}
          })
      )

    bar_html =
      render_component(&BOTelemetryComponents.bar_chart/1,
        id: "bar-empty",
        chart:
          DashboardChart.new(%{
            id: "bar-empty",
            kind: :bar,
            title: "Bar",
            summary: %{bars: []},
            meta: %{}
          })
      )

    donut_html =
      render_component(&BOTelemetryComponents.donut_chart/1,
        id: "donut-empty",
        chart:
          DashboardChart.new(%{
            id: "donut-empty",
            kind: :donut,
            title: "Donut",
            summary: %{segments: []},
            meta: %{}
          })
      )

    radar_html =
      render_component(&BOTelemetryComponents.radar_chart/1,
        id: "radar-empty",
        chart:
          DashboardChart.new(%{
            id: "radar-empty",
            kind: :radar,
            title: "Radar",
            summary: %{axes: []},
            meta: %{}
          })
      )

    assert line_html =~ "id=\"line-empty\""
    assert bar_html =~ "id=\"bar-empty\""
    assert donut_html =~ "id=\"donut-empty\""
    assert radar_html =~ "id=\"radar-empty\""

    assert line_html =~ "No data"
    assert bar_html =~ "No data"
    assert donut_html =~ "No data"
    assert radar_html =~ "No data"
  end

  defp extract_data_number(html, attr) do
    regex = Regex.compile!(~s/#{attr}="(-?[0-9.]+)"/)

    case Regex.run(regex, html) do
      [_, value] ->
        {number, _} = Float.parse(value)
        number

      _ ->
        flunk("Could not extract numeric attribute #{attr}")
    end
  end
end
