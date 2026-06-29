defmodule ZaqWeb.Components.BOTelemetryComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}

  alias Zaq.Engine.Telemetry.Contracts.Payloads.{
    CategoryVectorPayload,
    ProgressPayload,
    SeriesPayload,
    StatusListPayload
  }

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

  test "metric_card/1 renders display metadata and primary link from runtime href" do
    html =
      render_component(&BOTelemetryComponents.metric_card/1,
        id: "metric-runtime-separation-card",
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
    assert html =~ ~s(href="/bo/hidden-runtime")
    assert html =~ ~s(id="metric-runtime-separation")
    refute html =~ ~s(id="metric-runtime-separation-card" href=)
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
    refute html =~ "data-time-series-lane=\"secondary\""
    assert html =~ "Primary"
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
    assert html =~ "text-amber-700"
    assert html =~ "bg-amber-500"
  end

  test "time_series_chart/1 hides benchmark lane when benchmark data is missing" do
    html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        id: "chart-traffic-no-benchmark",
        chart:
          DashboardChart.new(%{
            id: "chart-traffic-no-benchmark",
            kind: :time_series,
            title: "Traffic",
            labels: ["Mon", "Tue", "Wed"],
            series: [%{key: "primary", name: "Primary", values: [120, 132, 128]}],
            summary: %{benchmarks: %{}},
            meta: %{}
          })
      )

    refute html =~ "data-time-series-lane=\"benchmark\""
    refute html =~ "Mon benchmark"
  end

  test "time_series_chart/1 renders baseline lane from scalar baseline" do
    html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        id: "chart-traffic-baseline",
        chart:
          DashboardChart.new(%{
            id: "chart-traffic-baseline",
            kind: :time_series,
            title: "Traffic",
            labels: ["Mon", "Tue", "Wed"],
            baseline: %{for: "primary", value: 100.0, label: "SLA"},
            series: [%{key: "primary", name: "Primary", values: [120, 132, 128]}],
            summary: %{},
            meta: %{}
          })
      )

    assert html =~ "data-time-series-lane=\"baseline\""
    assert html =~ "Mon SLA"
  end

  test "time_series_chart/1 renders baseline and benchmark lanes simultaneously" do
    html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        id: "chart-traffic-baseline-and-benchmark",
        chart:
          DashboardChart.new(%{
            id: "chart-traffic-baseline-and-benchmark",
            kind: :time_series,
            title: "Traffic",
            labels: ["Mon", "Tue", "Wed"],
            baseline: %{for: "primary", value: 100.0, label: "Alert threshold"},
            series: [%{key: "primary", name: "Primary", values: [120, 132, 128]}],
            summary: %{benchmarks: %{"primary" => [98, 104, 108]}},
            meta: %{}
          })
      )

    assert html =~ "data-time-series-lane=\"benchmark\""
    assert html =~ "data-time-series-lane=\"baseline\""
    assert html =~ "Mon benchmark"
    assert html =~ "Mon Alert threshold"
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

  test "time_series_chart/1 accepts precomputed assigns when chart is not a DashboardChart" do
    html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        chart: %{},
        id: "manual-line",
        title: "Manual",
        primary_label: "Manual primary",
        secondary_label: nil,
        points: [%{x: "X1", y: "12.5"}, %{y: 7, label: "Y only"}, 3, :bad],
        secondary_points: [%{y: 5}, 6, :bad],
        benchmark_points: [],
        baseline_points: [],
        width: 420,
        height: 180
      )

    assert html =~ "id=\"manual-line\""
    assert html =~ "Manual"
    assert html =~ ~s(data-line-x-axis-label="X1")
    assert html =~ "Y only"
    assert html =~ ~s(data-line-x-axis-label="T3")
    assert html =~ ~s(data-tip-label="T4")
    assert html =~ ~s(data-tip-value="0")
  end

  test "time_series_chart/1 renders No data for an empty manual chart" do
    html =
      render_component(&BOTelemetryComponents.time_series_chart/1,
        chart: %{},
        id: "manual-line-empty",
        title: "Manual empty",
        primary_label: "Manual primary",
        secondary_label: nil,
        points: [],
        secondary_points: [],
        benchmark_points: [],
        baseline_points: [],
        width: 420,
        height: 180
      )

    assert html =~ "id=\"manual-line-empty\""
    assert html =~ "No data"
  end

  test "components read legacy summary from raw DashboardChart structs" do
    bar_html =
      render_component(&BOTelemetryComponents.bar_chart/1,
        id: "legacy-bars",
        chart: %DashboardChart{
          id: "legacy-bars",
          kind: :bar,
          title: "Legacy Bars",
          summary: %{bars: [10, :bad]}
        }
      )

    donut_html =
      render_component(&BOTelemetryComponents.donut_chart/1,
        id: "legacy-donut",
        chart: %DashboardChart{
          id: "legacy-donut",
          kind: :donut,
          title: "Legacy Donut",
          summary: %{segments: [25, :bad]}
        }
      )

    gauge_html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "legacy-gauge",
        chart: %DashboardChart{
          id: "legacy-gauge",
          kind: :gauge,
          title: "Legacy Gauge",
          summary: %{value: 42, min: 0, max: 100}
        }
      )

    status_html =
      render_component(&BOTelemetryComponents.status_grid/1,
        id: "legacy-status",
        chart: %DashboardChart{
          id: "legacy-status",
          kind: :status_grid,
          title: "Legacy Status",
          summary: %{items: ["Plain service", 123]}
        }
      )

    progress_html =
      render_component(&BOTelemetryComponents.progress_countdown/1,
        id: "legacy-progress",
        chart: %DashboardChart{
          id: "legacy-progress",
          kind: :progress,
          title: "Legacy Progress",
          summary: %{total: 10, remaining: 4}
        }
      )

    radar_html =
      render_component(&BOTelemetryComponents.radar_chart/1,
        id: "legacy-radar",
        chart: %DashboardChart{
          id: "legacy-radar",
          kind: :radar,
          title: "Legacy Radar",
          summary: %{axes: [10, :bad, %{label: "Named", value: "30"}], benchmark_axes: [5, 6, 7]}
        }
      )

    assert bar_html =~ "id=\"legacy-bars\""
    assert bar_html =~ "10"
    assert bar_html =~ "0"
    assert bar_html =~ "width: 0%"

    assert donut_html =~ "id=\"legacy-donut\""
    assert donut_html =~ ~s(data-tip-label="1")
    assert donut_html =~ ~s|data-tip-value="25 (100%)"|
    assert donut_html =~ "0 (0%)"

    assert gauge_html =~ "id=\"legacy-gauge\""
    assert gauge_html =~ ">42<"
    assert gauge_html =~ "0 - 100"

    assert status_html =~ "Plain service"
    assert status_html =~ "Unknown"
    assert status_html =~ "bg-slate-300"

    assert progress_html =~ "60%"
    assert progress_html =~ "remaining of 10"

    assert radar_html =~ "id=\"legacy-radar\""
    assert radar_html =~ "Axis 1"
    assert radar_html =~ "Axis 2"
    assert radar_html =~ "Named"
    assert radar_html =~ "30"
    assert radar_html =~ "data-radar-series=\"benchmark\""
  end

  test "typed payload charts normalize mixed entry values" do
    bar_html =
      render_component(&BOTelemetryComponents.bar_chart/1,
        id: "typed-bars",
        chart: %DashboardChart{
          id: "typed-bars",
          kind: :bar,
          title: "Typed Bars",
          payload: %CategoryVectorPayload{entries: [12, :bad]}
        }
      )

    donut_html =
      render_component(&BOTelemetryComponents.donut_chart/1,
        id: "typed-donut",
        chart: %DashboardChart{
          id: "typed-donut",
          kind: :donut,
          title: "Typed Donut",
          payload: %CategoryVectorPayload{entries: [12, :bad]}
        }
      )

    status_html =
      render_component(&BOTelemetryComponents.status_grid/1,
        id: "typed-status",
        chart: %DashboardChart{
          id: "typed-status",
          kind: :status_grid,
          title: "Typed Status",
          payload: %StatusListPayload{items: ["String status", :bad]}
        }
      )

    progress_html =
      render_component(&BOTelemetryComponents.progress_countdown/1,
        id: "typed-progress",
        chart: %DashboardChart{
          id: "typed-progress",
          kind: :progress,
          title: "Typed Progress",
          payload: %ProgressPayload{total: 8, remaining: 2}
        }
      )

    radar_html =
      render_component(&BOTelemetryComponents.radar_chart/1,
        id: "typed-radar",
        chart: %DashboardChart{
          id: "typed-radar",
          kind: :radar,
          title: "Typed Radar",
          payload: %CategoryVectorPayload{
            entries: [10, :bad, %{label: "Parsed", value: "15.5"}],
            benchmark_entries: [1, 2, 3]
          }
        }
      )

    assert bar_html =~ ~s(<span class="font-mono">1</span>)
    assert bar_html =~ ~s(<span class="font-mono">2</span>)
    assert bar_html =~ ~s(<span class="font-mono text-slate-500">12</span>)
    assert bar_html =~ ~s(<span class="font-mono text-slate-500">0</span>)

    assert donut_html =~ ~s(data-tip-label="1")
    assert donut_html =~ ~s|data-tip-value="12 (100%)"|
    assert donut_html =~ "0 (0%)"

    assert status_html =~ "String status"
    assert status_html =~ "Unknown"

    assert progress_html =~ "75%"
    assert progress_html =~ "remaining of 8"

    assert radar_html =~ "Axis 1"
    assert radar_html =~ "Axis 2"
    assert radar_html =~ "Parsed"
    assert radar_html =~ "15.5"
    assert radar_html =~ "data-radar-series=\"benchmark\""
  end

  test "bar_chart/1 handles non-positive max values" do
    html =
      render_component(&BOTelemetryComponents.bar_chart/1,
        id: "bar-zero-max",
        chart: %DashboardChart{
          id: "bar-zero-max",
          kind: :bar,
          title: "Zero max",
          summary: %{bars: [%{label: "Zero", value: 0}, %{label: "Bad", value: :bad}]}
        }
      )

    assert html =~ "Zero"
    assert html =~ "Bad"
    assert html =~ "width: 0%"
  end

  test "status_grid/1 maps all status aliases and fallback classes" do
    html =
      render_component(&BOTelemetryComponents.status_grid/1,
        id: "status-aliases",
        chart: %DashboardChart{
          id: "status-aliases",
          kind: :status_grid,
          title: "Status aliases",
          summary: %{
            items: [
              %{label: "Up", status: :up},
              %{label: "Warning", status: :warning},
              %{label: "Down", status: :down},
              %{label: "Error", status: :error},
              %{label: "Unexpected", status: :unexpected}
            ]
          }
        }
      )

    assert html =~ "Up"
    assert html =~ "Warning"
    assert html =~ "Down"
    assert html =~ "Error"
    assert html =~ "Unexpected"
    assert html =~ "bg-cyan-500"
    assert html =~ "bg-slate-400"
    assert html =~ "bg-slate-700"
    assert html =~ "bg-slate-300"
  end

  test "gauge_chart/1 clamps below min and above max" do
    low_html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-low",
        chart: %DashboardChart{
          id: "gauge-low",
          kind: :gauge,
          title: "Gauge low",
          summary: %{value: -10, min: 0, max: 100}
        }
      )

    high_html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-high-clamp",
        chart: %DashboardChart{
          id: "gauge-high-clamp",
          kind: :gauge,
          title: "Gauge high",
          summary: %{value: 150, min: 0, max: 100}
        }
      )

    low_x = extract_data_number(low_html, "data-pointer-x")
    high_x = extract_data_number(high_html, "data-pointer-x")

    assert low_html =~ ~s(text-2xl font-semibold text-slate-900">0</p>)
    assert high_html =~ ~s(text-2xl font-semibold text-slate-900">100</p>)
    assert low_x < high_x
    assert low_x < 110
    assert high_x > 110
  end

  test "gauge_chart/1 uses two-point semicircle for tiny positive ratios" do
    html =
      render_component(&BOTelemetryComponents.gauge_chart/1,
        id: "gauge-tiny",
        chart: %DashboardChart{
          id: "gauge-tiny",
          kind: :gauge,
          title: "Gauge tiny",
          summary: %{value: 1, min: 0, max: 1000}
        }
      )

    assert html =~ ~r/data-gauge-ratio="0(\.0+)?"/
    assert html =~ "<polyline"
  end

  test "donut_chart/1 omits zero-length arcs but keeps legend" do
    html =
      render_component(&BOTelemetryComponents.donut_chart/1,
        id: "donut-zero-length",
        chart: %DashboardChart{
          id: "donut-zero-length",
          kind: :donut,
          title: "Donut zero",
          summary: %{segments: [%{label: "Zero", value: 0}, %{label: "Full", value: 10}]}
        }
      )

    assert html =~ "Zero"
    assert html =~ "Full"
    assert html =~ ~s(data-tip-label="Full")
    refute html =~ ~s(data-tip-label="Zero")
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
