defmodule ZaqWeb.Live.BO.TelemetryPreviewData do
  @moduledoc """
  Deterministic fallback payload for the telemetry preview page.

  The payload mirrors the canonical telemetry dashboard contract
  (`filters` + `charts`) and also includes convenience keys used by
  existing preview assigns.
  """

  @ranges ["24h", "7d", "30d", "90d"]
  @segments ["size", "geography", "industry"]
  @feedback_scopes ["critical", "all"]
  @series_keys ["availability", "latency", "deflection"]

  def default_filters do
    %{
      range: "7d",
      benchmark_opt_in: false,
      segment: "size",
      feedback_scope: "critical",
      series_visibility: %{
        "availability" => true,
        "latency" => true,
        "deflection" => true
      }
    }
  end

  def available_ranges, do: @ranges
  def available_segments, do: @segments
  def available_feedback_scopes, do: @feedback_scopes
  def available_series_keys, do: @series_keys

  def build(filters) do
    range = Map.get(filters, :range, "7d")
    segment = Map.get(filters, :segment, "size")
    feedback_scope = Map.get(filters, :feedback_scope, "critical")
    benchmark_opt_in = Map.get(filters, :benchmark_opt_in, false)

    metrics = [
      %{
        id: "metric-total-events",
        label: "Total Events",
        value: 0,
        unit: nil,
        trend: 0.0,
        hint: "#{String.upcase(segment)} segment"
      },
      %{
        id: "metric-availability",
        label: "Availability",
        value: 0.0,
        unit: "%",
        trend: 0.0,
        hint: "scope: #{feedback_scope}"
      },
      %{
        id: "metric-latency",
        label: "Median Latency",
        value: 0,
        unit: "ms",
        trend: 0.0,
        hint: "p50 user response"
      },
      %{
        id: "metric-quality",
        label: "Quality Score",
        value: 0.0,
        unit: nil,
        trend: 0.0,
        hint: "derived telemetry score"
      }
    ]

    time_series = %{
      labels: [],
      series: [
        %{key: "availability", name: "Availability", values: []},
        %{key: "latency", name: "Latency", values: []},
        %{key: "deflection", name: "Deflection", values: []},
        %{key: "benchmark", name: "Benchmark", values: []}
      ],
      values: %{
        "availability" => [],
        "latency" => [],
        "deflection" => []
      },
      benchmarks: %{
        "availability" => [],
        "latency" => [],
        "deflection" => []
      }
    }

    bar_chart = %{bars: []}
    donut_chart = %{segments: []}
    gauge_chart = %{value: 0.0, benchmark_value: nil, max: 100.0, label: "target 80%"}
    status_grid = %{items: []}
    progress_countdown = %{total: 240, remaining: 240}
    radar_chart = %{axes: [], benchmark_axes: []}

    charts = [
      %{
        id: "metric_cards",
        kind: :metric_cards,
        title: "Overview",
        labels: [],
        series: [],
        summary: %{metrics: metrics},
        meta: %{}
      },
      %{
        id: "time_series",
        kind: :time_series,
        title: "Signals over time",
        labels: [],
        series: time_series.series,
        summary: %{labels: [], values: time_series.values, benchmarks: time_series.benchmarks},
        meta: %{range: range}
      },
      %{
        id: "bar",
        kind: :bar,
        title: "Top intents",
        labels: [],
        series: [],
        summary: bar_chart,
        meta: %{}
      },
      %{
        id: "donut",
        kind: :donut,
        title: "Feedback distribution",
        labels: [],
        series: [],
        summary: donut_chart,
        meta: %{}
      },
      %{
        id: "gauge",
        kind: :gauge,
        title: "Automation score",
        labels: [],
        series: [],
        summary: gauge_chart,
        meta: %{}
      },
      %{
        id: "status_grid",
        kind: :status_grid,
        title: "Service status",
        labels: [],
        series: [],
        summary: status_grid,
        meta: %{}
      },
      %{
        id: "progress",
        kind: :progress,
        title: "SLA countdown",
        labels: [],
        series: [],
        summary: progress_countdown,
        meta: %{}
      },
      %{
        id: "radar",
        kind: :radar,
        title: "Capability profile",
        labels: [],
        series: [],
        summary: radar_chart,
        meta: %{}
      }
    ]

    %{
      filters: %{
        range: range,
        benchmark_opt_in: benchmark_opt_in,
        segment: segment,
        feedback_scope: feedback_scope
      },
      charts: charts,
      metrics: metrics,
      time_series: time_series,
      bar_chart: bar_chart,
      donut_chart: donut_chart,
      gauge_chart: gauge_chart,
      status_grid: status_grid,
      progress_countdown: progress_countdown,
      radar_chart: radar_chart
    }
  end
end
