defmodule ZaqWeb.Live.BO.TelemetryPreviewData do
  @moduledoc """
  Deterministic dummy data for the telemetry preview page.
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
    range = filters.range
    segment = filters.segment
    feedback_scope = filters.feedback_scope

    range_factor = factor(range, @ranges)
    segment_factor = factor(segment, @segments)
    feedback_factor = factor(feedback_scope, @feedback_scopes)

    points_count = points_count(range)
    labels = labels_for_range(range, points_count)

    availability =
      build_series(
        points_count,
        95.4 + segment_factor * 0.4 + range_factor * 0.25 - feedback_factor * 0.2,
        0.35
      )

    latency =
      build_series(
        points_count,
        420 - segment_factor * 12 + feedback_factor * 15 + range_factor * 6,
        18
      )

    deflection =
      build_series(
        points_count,
        68 + segment_factor * 1.2 + range_factor * 0.7 - feedback_factor * 0.8,
        1.1
      )

    metric_base =
      1700 + range_factor * 420 + segment_factor * 70 - feedback_factor * 55

    quality_score =
      Float.round(82.0 + segment_factor * 1.3 - feedback_factor * 2.0 + range_factor * 0.8, 1)

    %{
      metrics: [
        %{
          id: "metric-total-events",
          label: "Total Events",
          value: metric_base,
          unit: nil,
          trend: Float.round(2.0 + range_factor * 0.6 + segment_factor * 0.4, 2),
          hint: "#{String.upcase(segment)} segment"
        },
        %{
          id: "metric-availability",
          label: "Availability",
          value: Float.round(List.last(availability), 1),
          unit: "%",
          trend: Float.round(0.6 + range_factor * 0.3, 2),
          hint: "scope: #{feedback_scope}"
        },
        %{
          id: "metric-latency",
          label: "Median Latency",
          value: round(List.last(latency)),
          unit: "ms",
          trend: -Float.round(8.0 + segment_factor * 3.0, 2),
          hint: "p50 user response"
        },
        %{
          id: "metric-quality",
          label: "Quality Score",
          value: quality_score,
          unit: nil,
          trend: Float.round(0.7 + segment_factor * 0.4, 2),
          hint: "derived synthetic score"
        }
      ],
      time_series: %{
        labels: labels,
        series: [
          %{key: "availability", name: "Availability"},
          %{key: "latency", name: "Latency"},
          %{key: "deflection", name: "Deflection"}
        ],
        values: %{
          "availability" => availability,
          "latency" => latency,
          "deflection" => deflection
        },
        benchmarks: %{
          "availability" => Enum.map(availability, &Float.round(&1 - 0.7, 2)),
          "latency" => Enum.map(latency, &Float.round(&1 + 18, 2)),
          "deflection" => Enum.map(deflection, &Float.round(&1 - 3.5, 2))
        }
      },
      bar_chart: %{
        bars: [
          %{label: "Password reset", value: 110 + range_factor * 7 + segment_factor * 3},
          %{label: "Billing", value: 96 + range_factor * 6 + feedback_factor * 5},
          %{label: "Provisioning", value: 82 + segment_factor * 4},
          %{label: "Permissions", value: 73 + range_factor * 4}
        ]
      },
      donut_chart: %{
        segments: [
          %{label: "Auto-resolved", value: 58 + segment_factor * 3},
          %{label: "Escalated", value: 27 + feedback_factor * 4},
          %{label: "Pending", value: 15 + range_factor * 2}
        ]
      },
      gauge_chart: %{
        value:
          Float.round(72.0 + segment_factor * 3.3 - feedback_factor * 2.6 + range_factor * 1.2, 1),
        max: 100.0,
        label: "target 80%"
      },
      status_grid: %{
        items: [
          %{label: "Engine", detail: "healthy", status: :ok},
          %{label: "Agent", detail: "healthy", status: :ok},
          %{label: "Ingestion", detail: "degraded", status: :warn},
          %{label: "Channels", detail: "healthy", status: :ok}
        ]
      },
      progress_countdown: %{
        total: 240,
        remaining: 92 - range_factor * 12 + feedback_factor * 8 + segment_factor * 4
      },
      radar_chart: %{
        axes: [
          %{label: "Trust", value: 70 + segment_factor * 7},
          %{label: "Speed", value: 66 + range_factor * 6},
          %{label: "Coverage", value: 62 + range_factor * 4 + segment_factor * 3},
          %{label: "Tone", value: 74 - feedback_factor * 6},
          %{label: "Citations", value: 79 + segment_factor * 4}
        ]
      }
    }
  end

  defp factor(value, list) do
    Enum.find_index(list, fn item -> item == value end) || 0
  end

  defp points_count("24h"), do: 6
  defp points_count("7d"), do: 7
  defp points_count("30d"), do: 10
  defp points_count("90d"), do: 12
  defp points_count(_), do: 7

  defp labels_for_range("24h", _points_count),
    do: ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"]

  defp labels_for_range("7d", _points_count),
    do: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

  defp labels_for_range("30d", _points_count),
    do: Enum.map(0..9, fn idx -> "D#{idx * 3 + 1}" end)

  defp labels_for_range("90d", _points_count),
    do: Enum.map(1..12, fn idx -> "W#{idx}" end)

  defp labels_for_range(_range, points_count),
    do: Enum.map(1..points_count, fn idx -> "T#{idx}" end)

  defp build_series(points_count, base, step) do
    1..points_count
    |> Enum.map(fn idx ->
      wave = :math.sin(idx / 2) * step
      Float.round(base + idx * (step / 3) + wave, 2)
    end)
  end
end
