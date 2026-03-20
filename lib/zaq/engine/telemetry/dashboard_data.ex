defmodule Zaq.Engine.Telemetry.DashboardData do
  @moduledoc """
  Standardized dashboard data loader.

  The public contract is stable across chart types:

      %{
        filters: %{...},
        charts: [
          %{id: "time_series", kind: :time_series, title: "Signals", labels: [...], series: [...], summary: %{...}, meta: %{...}}
        ]
      }

  BO LiveViews can consume this payload directly or map it to component assigns.
  """

  import Ecto.Query

  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Repo

  @chart_ids [
    "metric_cards",
    "time_series",
    "bar",
    "donut",
    "gauge",
    "status_grid",
    "progress",
    "radar"
  ]

  @spec load_dashboard(map()) :: map()
  def load_dashboard(filters) do
    normalized = normalize_filters(filters)
    labels = labels_for_range(normalized.range)

    local_rows = load_rollups(labels.from, "local")
    benchmark_rows = load_rollups(labels.from, "benchmark")

    charts =
      if local_rows == [] do
        empty_charts(labels, normalized)
      else
        build_charts(local_rows, benchmark_rows, labels, normalized)
      end

    dashboard_payload(charts, normalized)
  end

  @spec load_chart(String.t(), map()) :: {:ok, map()} | {:error, :unknown_chart}
  def load_chart(chart_id, filters) do
    if chart_id in @chart_ids do
      dashboard = load_dashboard(filters)
      {:ok, chart!(dashboard.charts, chart_id)}
    else
      {:error, :unknown_chart}
    end
  end

  @spec load_llm_performance(map()) :: map()
  def load_llm_performance(filters) do
    normalized = normalize_filters(filters)
    labels = labels_for_range(normalized.range)
    local_rows = load_rollups(labels.from, "local")

    llm_api_calls = sum_points(local_rows, "qa.tokens.total", labels.labels, :value_count)
    input_tokens = sum_points(local_rows, "qa.tokens.prompt", labels.labels, :value_sum)
    output_tokens = sum_points(local_rows, "qa.tokens.completion", labels.labels, :value_sum)

    question_count = sum_metric(local_rows, "qa.question.count")
    no_answer_count = sum_metric(local_rows, "qa.no_answer.count")

    retrieval_effectiveness =
      no_answer_count
      |> ratio_or_zero(question_count)
      |> then(&(1.0 - &1))
      |> Kernel.*(100.0)
      |> max(0.0)
      |> min(100.0)
      |> Float.round(1)

    charts = [
      %{
        id: "llm_api_calls",
        kind: :time_series,
        title: "LLM API calls",
        labels: labels.labels,
        series: [%{key: "calls", name: "API calls", values: llm_api_calls}],
        summary: %{
          labels: labels.labels,
          values: %{"calls" => llm_api_calls}
        },
        meta: %{range: normalized.range}
      },
      %{
        id: "token_usage",
        kind: :time_series,
        title: "Token usage",
        labels: labels.labels,
        series: [
          %{key: "output_tokens", name: "Output tokens", values: output_tokens},
          %{key: "input_tokens", name: "Input tokens", values: input_tokens}
        ],
        summary: %{
          labels: labels.labels,
          values: %{
            "output_tokens" => output_tokens,
            "input_tokens" => input_tokens
          }
        },
        meta: %{range: normalized.range}
      },
      %{
        id: "retrieval_effectiveness",
        kind: :gauge,
        title: "Retrieval effectiveness",
        labels: [],
        series: [],
        summary: %{value: retrieval_effectiveness, max: 100.0, label: "strict no-answer adjusted"},
        meta: %{question_count: question_count, no_answer_count: no_answer_count}
      }
    ]

    %{
      filters: %{range: normalized.range},
      charts: charts,
      llm_api_calls_chart: chart!(charts, "llm_api_calls"),
      token_usage_chart: chart!(charts, "token_usage"),
      retrieval_effectiveness_chart: chart!(charts, "retrieval_effectiveness")
    }
  end

  defp build_charts(local_rows, benchmark_rows, labels, filters) do
    latency_points =
      metric_points(local_rows, "qa.answer.latency_ms", labels.labels)

    confidence_points =
      metric_points(local_rows, "qa.answer.confidence", labels.labels, fn v ->
        Float.round(v * 100, 2)
      end)

    no_answer_points =
      ratio_points(
        local_rows,
        "qa.no_answer.count",
        "qa.question.count",
        labels.labels,
        fn ratio -> Float.round((1.0 - ratio) * 100, 2) end
      )

    benchmark_latency =
      metric_points(benchmark_rows, "qa.answer.latency_ms", labels.labels)

    feedback_neg = sum_metric(local_rows, "feedback.negative.count")
    feedback_total = sum_metric(local_rows, "feedback.rating")
    feedback_ratio = ratio_or_zero(feedback_neg, feedback_total)

    total_questions = sum_metric(local_rows, "qa.question.count")
    total_ingestions = sum_metric(local_rows, "ingestion.completed.count")

    [
      %{
        id: "metric_cards",
        kind: :metric_cards,
        title: "Overview",
        labels: [],
        series: [],
        summary: %{
          metrics: [
            %{
              id: "metric-total-events",
              label: "Total Events",
              value: total_questions + total_ingestions,
              unit: nil,
              trend: 0.0,
              hint: String.upcase(filters.segment) <> " segment"
            },
            %{
              id: "metric-availability",
              label: "Availability",
              value: latest_or_default(confidence_points, 97.0),
              unit: "%",
              trend: 0.0,
              hint: "scope: " <> filters.feedback_scope
            },
            %{
              id: "metric-latency",
              label: "Median Latency",
              value: round(latest_or_default(latency_points, 420.0)),
              unit: "ms",
              trend: 0.0,
              hint: "p50 user response"
            },
            %{
              id: "metric-quality",
              label: "Quality Score",
              value: Float.round(latest_or_default(no_answer_points, 84.0), 1),
              unit: nil,
              trend: 0.0,
              hint: "derived telemetry score"
            }
          ]
        },
        meta: %{}
      },
      %{
        id: "time_series",
        kind: :time_series,
        title: "Signals over time",
        labels: labels.labels,
        series: [
          %{key: "availability", name: "Availability", values: confidence_points},
          %{key: "latency", name: "Latency", values: latency_points},
          %{key: "deflection", name: "Deflection", values: no_answer_points},
          %{key: "benchmark", name: "Benchmark", values: benchmark_latency}
        ],
        summary: %{
          labels: labels.labels,
          values: %{
            "availability" => confidence_points,
            "latency" => latency_points,
            "deflection" => no_answer_points
          },
          benchmarks: %{"latency" => benchmark_latency}
        },
        meta: %{range: filters.range}
      },
      %{
        id: "bar",
        kind: :bar,
        title: "Top intents",
        labels: [],
        series: [],
        summary: %{
          bars: [
            %{label: "Questions", value: total_questions},
            %{label: "Completed ingestion", value: total_ingestions},
            %{label: "Negative feedback", value: feedback_neg},
            %{label: "No answer", value: sum_metric(local_rows, "qa.no_answer.count")}
          ]
        },
        meta: %{}
      },
      %{
        id: "donut",
        kind: :donut,
        title: "Feedback distribution",
        labels: [],
        series: [],
        summary: %{
          segments: [
            %{label: "Positive", value: max(feedback_total - feedback_neg, 0)},
            %{label: "Negative", value: feedback_neg},
            %{label: "Unrated", value: max(total_questions - feedback_total, 0)}
          ]
        },
        meta: %{}
      },
      %{
        id: "gauge",
        kind: :gauge,
        title: "Automation score",
        labels: [],
        series: [],
        summary: %{
          value: Float.round((1.0 - feedback_ratio) * 100, 1),
          max: 100.0,
          label: "target 80%"
        },
        meta: %{}
      },
      %{
        id: "status_grid",
        kind: :status_grid,
        title: "Service status",
        labels: [],
        series: [],
        summary: %{
          items: [
            %{label: "Engine", detail: "healthy", status: :ok},
            %{label: "Agent", detail: "healthy", status: :ok},
            %{label: "Ingestion", detail: "healthy", status: :ok},
            %{label: "Channels", detail: "healthy", status: :ok}
          ]
        },
        meta: %{}
      },
      %{
        id: "progress",
        kind: :progress,
        title: "SLA countdown",
        labels: [],
        series: [],
        summary: %{total: 240, remaining: max(240 - round(total_questions), 0)},
        meta: %{}
      },
      %{
        id: "radar",
        kind: :radar,
        title: "Capability profile",
        labels: [],
        series: [],
        summary: %{
          axes: [
            %{label: "Trust", value: Float.round((1.0 - feedback_ratio) * 100, 1)},
            %{label: "Speed", value: percentile_from_latency(latency_points)},
            %{label: "Coverage", value: latest_or_default(no_answer_points, 70.0)},
            %{label: "Tone", value: max(100 - feedback_neg * 5, 35)},
            %{
              label: "Citations",
              value: max(60 + round(sum_metric(local_rows, "qa.answer.count") / 5), 60)
            }
          ]
        },
        meta: %{}
      }
    ]
  end

  defp load_rollups(from_dt, source) do
    from(r in Rollup,
      where: r.source == ^source and r.bucket_size == "10m" and r.bucket_start >= ^from_dt
    )
    |> Repo.all()
  end

  defp metric_points(rows, metric_key, labels, transform \\ & &1) do
    by_label =
      rows
      |> Enum.filter(&(&1.metric_key == metric_key))
      |> Map.new(fn row ->
        {label_for_bucket(row.bucket_start, labels), apply_transform(row, transform)}
      end)

    Enum.map(labels, fn label -> Map.get(by_label, label, 0.0) end)
  end

  defp ratio_points(rows, numerator_key, denominator_key, labels, transform) do
    numerators = metric_points(rows, numerator_key, labels)
    denominators = metric_points(rows, denominator_key, labels)

    Enum.zip(numerators, denominators)
    |> Enum.map(fn {n, d} ->
      ratio = if d <= 0, do: 0.0, else: n / d
      transform.(ratio)
    end)
  end

  defp sum_points(rows, metric_key, labels, field) when field in [:value_sum, :value_count] do
    by_label =
      rows
      |> Enum.filter(&(&1.metric_key == metric_key))
      |> Enum.reduce(%{}, fn row, acc ->
        label = label_for_bucket(row.bucket_start, labels)
        amount = Map.get(row, field, 0.0)
        Map.update(acc, label, amount, &(&1 + amount))
      end)

    Enum.map(labels, fn label ->
      by_label
      |> Map.get(label, 0.0)
      |> Kernel.*(1.0)
      |> Float.round(2)
    end)
  end

  defp sum_metric(rows, metric_key) do
    rows
    |> Enum.filter(&(&1.metric_key == metric_key))
    |> Enum.reduce(0.0, fn row, acc -> acc + row.value_sum end)
    |> Float.round(2)
  end

  defp apply_transform(row, transform) do
    if row.value_count <= 0 do
      0.0
    else
      transform.(Float.round(row.value_sum / row.value_count, 2))
    end
  end

  defp label_for_bucket(bucket_start, labels) do
    minute = bucket_start.minute
    hour = bucket_start.hour

    cond do
      Enum.any?(labels, &String.contains?(&1, ":")) ->
        [hour, minute]
        |> Enum.map_join(":", &(Integer.to_string(&1) |> String.pad_leading(2, "0")))

      Enum.any?(labels, &(&1 in ~w[Mon Tue Wed Thu Fri Sat Sun])) ->
        bucket_start
        |> DateTime.to_date()
        |> Date.day_of_week()
        |> day_name()

      Enum.any?(labels, &String.starts_with?(&1, "W")) ->
        date = DateTime.to_date(bucket_start)
        {_year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
        "W" <> Integer.to_string(week)

      true ->
        "D" <> Integer.to_string(bucket_start.day)
    end
  end

  defp day_name(1), do: "Mon"
  defp day_name(2), do: "Tue"
  defp day_name(3), do: "Wed"
  defp day_name(4), do: "Thu"
  defp day_name(5), do: "Fri"
  defp day_name(6), do: "Sat"
  defp day_name(7), do: "Sun"

  defp chart!(charts, id), do: Enum.find(charts, &(&1.id == id))

  defp dashboard_payload(charts, filters) do
    %{
      filters: filters,
      charts: charts,
      metrics: chart!(charts, "metric_cards").summary.metrics,
      time_series: chart!(charts, "time_series"),
      bar_chart: chart!(charts, "bar").summary,
      donut_chart: chart!(charts, "donut").summary,
      gauge_chart: chart!(charts, "gauge").summary,
      status_grid: chart!(charts, "status_grid").summary,
      progress_countdown: chart!(charts, "progress").summary,
      radar_chart: chart!(charts, "radar").summary
    }
  end

  defp latest_or_default([], default), do: default
  defp latest_or_default(values, _default), do: List.last(values)

  defp percentile_from_latency(values) do
    value = latest_or_default(values, 500.0)
    Float.round(max(0.0, min(100.0, 100.0 - value / 10.0)), 1)
  end

  defp ratio_or_zero(_n, d) when d <= 0, do: 0.0
  defp ratio_or_zero(n, d), do: n / d

  defp normalize_filters(filters) do
    %{
      range: Map.get(filters, :range) || Map.get(filters, "range") || "7d",
      benchmark_opt_in:
        Map.get(filters, :benchmark_opt_in) || Map.get(filters, "benchmark_opt_in") || false,
      segment: Map.get(filters, :segment) || Map.get(filters, "segment") || "size",
      feedback_scope:
        Map.get(filters, :feedback_scope) || Map.get(filters, "feedback_scope") || "critical"
    }
  end

  defp labels_for_range("24h"),
    do: %{
      labels: ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"],
      from: DateTime.add(DateTime.utc_now(), -24, :hour)
    }

  defp labels_for_range("7d"),
    do: %{
      labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
      from: DateTime.add(DateTime.utc_now(), -7, :day)
    }

  defp labels_for_range("30d"),
    do: %{
      labels: Enum.map(0..9, fn idx -> "D#{idx * 3 + 1}" end),
      from: DateTime.add(DateTime.utc_now(), -30, :day)
    }

  defp labels_for_range("90d"),
    do: %{
      labels: Enum.map(1..12, fn idx -> "W#{idx}" end),
      from: DateTime.add(DateTime.utc_now(), -90, :day)
    }

  defp labels_for_range(_), do: labels_for_range("7d")

  defp empty_charts(labels, filters) do
    base = Map.get(filters, :segment, "size")
    zeroes = Enum.map(labels.labels, fn _ -> 0.0 end)

    [
      %{
        id: "metric_cards",
        kind: :metric_cards,
        title: "Overview",
        labels: [],
        series: [],
        summary: %{
          metrics: [
            %{
              id: "metric-total-events",
              label: "Total Events",
              value: 0,
              unit: nil,
              trend: 0.0,
              hint: String.upcase(base) <> " segment"
            },
            %{
              id: "metric-availability",
              label: "Availability",
              value: 0.0,
              unit: "%",
              trend: 0.0,
              hint: "scope: " <> filters.feedback_scope
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
        },
        meta: %{}
      },
      %{
        id: "time_series",
        kind: :time_series,
        title: "Signals over time",
        labels: labels.labels,
        series: [
          %{key: "availability", name: "Availability", values: zeroes},
          %{key: "latency", name: "Latency", values: zeroes},
          %{key: "deflection", name: "Deflection", values: zeroes},
          %{key: "benchmark", name: "Benchmark", values: zeroes}
        ],
        summary: %{
          labels: labels.labels,
          values: %{
            "availability" => zeroes,
            "latency" => zeroes,
            "deflection" => zeroes
          },
          benchmarks: %{"latency" => zeroes}
        },
        meta: %{range: filters.range}
      },
      %{
        id: "bar",
        kind: :bar,
        title: "Top intents",
        labels: [],
        series: [],
        summary: %{
          bars: [
            %{label: "Questions", value: 0.0},
            %{label: "Completed ingestion", value: 0.0},
            %{label: "Negative feedback", value: 0.0},
            %{label: "No answer", value: 0.0}
          ]
        },
        meta: %{}
      },
      %{
        id: "donut",
        kind: :donut,
        title: "Feedback distribution",
        labels: [],
        series: [],
        summary: %{
          segments: [
            %{label: "Positive", value: 0.0},
            %{label: "Negative", value: 0.0},
            %{label: "Unrated", value: 0.0}
          ]
        },
        meta: %{}
      },
      %{
        id: "gauge",
        kind: :gauge,
        title: "Automation score",
        labels: [],
        series: [],
        summary: %{value: 0.0, max: 100.0, label: "target 80%"},
        meta: %{}
      },
      %{
        id: "status_grid",
        kind: :status_grid,
        title: "Service status",
        labels: [],
        series: [],
        summary: %{
          items: [
            %{label: "Engine", detail: "unknown", status: :unknown},
            %{label: "Agent", detail: "unknown", status: :unknown},
            %{label: "Ingestion", detail: "unknown", status: :unknown},
            %{label: "Channels", detail: "unknown", status: :unknown}
          ]
        },
        meta: %{}
      },
      %{
        id: "progress",
        kind: :progress,
        title: "SLA countdown",
        labels: [],
        series: [],
        summary: %{total: 240, remaining: 240},
        meta: %{}
      },
      %{
        id: "radar",
        kind: :radar,
        title: "Capability profile",
        labels: [],
        series: [],
        summary: %{
          axes: [
            %{label: "Trust", value: 0.0},
            %{label: "Speed", value: 0.0},
            %{label: "Coverage", value: 0.0},
            %{label: "Tone", value: 0.0},
            %{label: "Citations", value: 0.0}
          ]
        },
        meta: %{}
      }
    ]
  end
end
