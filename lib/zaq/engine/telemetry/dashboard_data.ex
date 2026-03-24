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

  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
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
    answer_count = sum_metric(local_rows, "qa.answer.count")
    no_answer_count = sum_metric(local_rows, "qa.no_answer.count")

    retrieval_effectiveness =
      if answer_count <= 0 do
        0.0
      else
        strict_effectiveness_score(no_answer_count, question_count)
      end

    legacy_charts = [
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
          %{key: "output_tokens", name: "Output token", values: output_tokens},
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
        summary: %{value: retrieval_effectiveness, max: 100.0, label: "Retrieval effectiveness"},
        meta: %{
          question_count: question_count,
          answer_count: answer_count,
          no_answer_count: no_answer_count
        }
      }
    ]

    charts = to_contract_charts(legacy_charts)

    %{
      filters: %{range: normalized.range},
      charts: charts,
      llm_api_calls_chart: chart!(charts, "llm_api_calls"),
      token_usage_chart: chart!(charts, "token_usage"),
      retrieval_effectiveness_chart: chart!(charts, "retrieval_effectiveness")
    }
  end

  @spec load_conversations_metrics(map()) :: map()
  def load_conversations_metrics(filters) do
    normalized = normalize_filters(filters)
    labels = labels_for_range(normalized.range)
    local_rows = load_rollups(labels.from, "local")

    question_points = sum_points(local_rows, "qa.question.count", labels.labels, :value_sum)
    cumulative_questions = cumulative_points(question_points)

    {no_answer_rate_points, no_answer_weights} =
      ratio_points(
        local_rows,
        "qa.no_answer.count",
        "qa.question.count",
        labels.labels,
        fn ratio -> Float.round(ratio * 100, 2) end
      )

    # Compute weighted averages per range for the no-answer rate chart
    no_answer_rate_weighted =
      compute_weighted_averages_per_range(no_answer_rate_points, no_answer_weights, labels.labels)

    response_time_points = metric_points(local_rows, "qa.answer.latency_ms", labels.labels)

    confidence_axes =
      confidence_distribution_axes(local_rows, [
        {"Over 90", "qa.answer.confidence.bucket.gt_90"},
        {"80-90", "qa.answer.confidence.bucket.between_80_90"},
        {"70-80", "qa.answer.confidence.bucket.between_70_80"},
        {"50-70", "qa.answer.confidence.bucket.between_50_70"},
        {"Below 50", "qa.answer.confidence.bucket.lt_50"}
      ])

    questions_by_channel =
      metric_distribution_by_dimension(local_rows, "qa.question.count", "channel_type")

    telemetry_config = Zaq.System.get_telemetry_config()
    no_answer_alert_threshold = telemetry_config.no_answer_alert_threshold_percent * 1.0
    response_sla_ms = telemetry_config.conversation_response_sla_ms * 1.0

    legacy_charts = [
      %{
        id: "questions_asked",
        kind: :time_series,
        title: "Questions asked",
        labels: labels.labels,
        series: [
          %{key: "questions", name: "Questions (cumulative)", values: cumulative_questions}
        ],
        summary: %{
          labels: labels.labels,
          values: %{"questions" => cumulative_questions}
        },
        meta: %{range: normalized.range}
      },
      %{
        id: "questions_per_channel",
        kind: :donut,
        title: "Questions per channel",
        labels: [],
        series: [],
        summary: %{segments: questions_by_channel},
        meta: %{range: normalized.range}
      },
      %{
        id: "answer_confidence_distribution",
        kind: :radar,
        title: "Answer confidence distribution",
        labels: [],
        series: [],
        summary: %{axes: confidence_axes},
        meta: %{range: normalized.range}
      },
      %{
        id: "no_answer_rate",
        kind: :time_series,
        title: "No-answer rate (%)",
        labels: labels.labels,
        baseline: %{
          for: "no_answer_rate",
          value: no_answer_alert_threshold,
          label: "Alert threshold"
        },
        series: [%{key: "no_answer_rate", name: "No-answer rate", values: no_answer_rate_weighted}],
        summary: %{
          labels: labels.labels,
          values: %{"no_answer_rate" => no_answer_rate_weighted}
        },
        meta: %{threshold_percent: no_answer_alert_threshold}
      },
      %{
        id: "average_response_time",
        kind: :time_series,
        title: "Average response time (ms)",
        labels: labels.labels,
        baseline: %{for: "average_response_time", value: response_sla_ms, label: "SLA"},
        series: [
          %{
            key: "average_response_time",
            name: "Average response time",
            values: response_time_points
          }
        ],
        summary: %{
          labels: labels.labels,
          values: %{"average_response_time" => response_time_points}
        },
        meta: %{sla_ms: response_sla_ms}
      }
    ]

    charts = to_contract_charts(legacy_charts)

    %{
      filters: %{range: normalized.range},
      charts: charts,
      questions_asked_chart: chart!(charts, "questions_asked"),
      questions_per_channel_chart: chart!(charts, "questions_per_channel"),
      answer_confidence_distribution_chart: chart!(charts, "answer_confidence_distribution"),
      no_answer_rate_chart: chart!(charts, "no_answer_rate"),
      average_response_time_chart: chart!(charts, "average_response_time")
    }
  end

  @spec load_knowledge_base_metrics(map()) :: map()
  def load_knowledge_base_metrics(filters) do
    normalized = normalize_filters(filters)
    labels = labels_for_range(normalized.range)

    previous_from =
      DateTime.add(labels.from, -window_seconds_for_range(normalized.range), :second)

    historical_rows = load_rollups(previous_from, "local")

    current_rows =
      historical_rows
      |> Enum.filter(&(DateTime.compare(&1.bucket_start, labels.from) in [:eq, :gt]))

    previous_rows =
      historical_rows
      |> Enum.filter(fn row ->
        DateTime.compare(row.bucket_start, previous_from) in [:eq, :gt] and
          DateTime.compare(row.bucket_start, labels.from) == :lt
      end)

    chunks_created = sum_metric(current_rows, "ingestion.chunks.created")
    chunks_created_previous = sum_metric(previous_rows, "ingestion.chunks.created")

    ingested_documents = sum_metric(current_rows, "ingestion.completed.count")
    ingested_documents_previous = sum_metric(previous_rows, "ingestion.completed.count")

    terminal_failed_documents =
      case sum_metric(current_rows, "ingestion.document.failed.count") do
        value when value <= 0.0 -> sum_metric(current_rows, "ingestion.failed.count")
        value -> value
      end

    ingestion_volume_points =
      sum_points(current_rows, "ingestion.completed.count", labels.labels, :value_sum)

    chunks_over_time_points =
      sum_points(current_rows, "ingestion.chunks.created", labels.labels, :value_sum)

    ingestion_success_rate =
      ingested_documents
      |> ratio_or_zero(ingested_documents + terminal_failed_documents)
      |> Kernel.*(100.0)
      |> Float.round(2)

    average_chunks_per_document =
      chunks_created
      |> ratio_or_zero(ingested_documents)
      |> Float.round(2)

    average_chunks_previous =
      chunks_created_previous
      |> ratio_or_zero(ingested_documents_previous)
      |> Float.round(2)

    charts =
      to_contract_charts([
        %{
          id: "total_chunks_created",
          kind: :metric_cards,
          title: "Total chunks created",
          labels: [],
          series: [],
          summary: %{
            metrics: [
              %{
                id: "knowledge-base-total-chunks-created",
                label: "Total chunks created",
                value: chunks_created,
                unit: nil,
                trend: percent_change(chunks_created, chunks_created_previous),
                hint: "growth versus previous period",
                meta: %{range: normalized.range}
              }
            ]
          },
          meta: %{range: normalized.range}
        },
        %{
          id: "ingestion_volume_over_time",
          kind: :time_series,
          title: "Ingestion volume over time",
          labels: labels.labels,
          series: [
            %{
              key: "documents_ingested",
              name: "Documents ingested",
              values: ingestion_volume_points
            },
            %{
              key: "chunks_created",
              name: "Chunks created",
              values: chunks_over_time_points
            }
          ],
          summary: %{
            labels: labels.labels,
            values: %{
              "documents_ingested" => ingestion_volume_points,
              "chunks_created" => chunks_over_time_points
            }
          },
          meta: %{range: normalized.range}
        },
        %{
          id: "ingestion_success_rate",
          kind: :gauge,
          title: "Ingestion success rate",
          labels: [],
          series: [],
          summary: %{
            value: ingestion_success_rate,
            max: 100.0,
            label: "terminal document success"
          },
          meta: %{
            range: normalized.range,
            completed_documents: ingested_documents,
            terminal_failed_documents: terminal_failed_documents
          }
        },
        %{
          id: "average_chunks_per_document",
          kind: :metric_cards,
          title: "Average chunks per document",
          labels: [],
          series: [],
          summary: %{
            metrics: [
              %{
                id: "knowledge-base-average-chunks-per-document",
                label: "Average chunks per document",
                value: average_chunks_per_document,
                unit: nil,
                trend: percent_change(average_chunks_per_document, average_chunks_previous),
                hint: "chunk density per successfully ingested document",
                meta: %{range: normalized.range}
              }
            ]
          },
          meta: %{range: normalized.range}
        }
      ])

    %{
      filters: %{range: normalized.range},
      charts: charts,
      total_chunks_created_chart: chart!(charts, "total_chunks_created"),
      ingestion_volume_chart: chart!(charts, "ingestion_volume_over_time"),
      ingestion_success_rate_chart: chart!(charts, "ingestion_success_rate"),
      average_chunks_per_document_chart: chart!(charts, "average_chunks_per_document")
    }
  end

  @spec load_main_dashboard_metrics(map()) :: map()
  def load_main_dashboard_metrics(filters) do
    normalized = normalize_filters(filters)
    labels = labels_for_range(normalized.range)
    local_rows = load_rollups(labels.from, "local")

    documents_ingested = sum_metric(local_rows, "ingestion.completed.count")
    llm_api_calls = sum_metric_count(local_rows, "qa.tokens.total")
    avg_response_time_ms = weighted_average_metric(local_rows, "qa.answer.latency_ms")

    metric_cards_chart = %{
      id: "main_dashboard_metrics",
      kind: :metric_cards,
      title: "Main dashboard metrics",
      labels: [],
      series: [],
      summary: %{
        metrics: [
          %{
            id: "dashboard-metric-documents-ingested",
            label: "Documents ingested",
            value: documents_ingested,
            unit: nil,
            trend: nil,
            hint: "ingestion pipeline completions",
            meta: %{range: normalized.range, href: "/bo/ingestion"}
          },
          %{
            id: "dashboard-metric-llm-api-calls",
            label: "LLM API calls",
            value: llm_api_calls,
            unit: nil,
            trend: nil,
            hint: "answering throughput",
            meta: %{range: normalized.range, href: "/bo/ai-diagnostics"}
          },
          %{
            id: "dashboard-metric-qa-response-time",
            label: "Conversations response time",
            value: avg_response_time_ms,
            unit: "ms",
            trend: nil,
            hint: "weighted mean latency",
            meta: %{range: normalized.range, href: "/bo/chat"}
          }
        ]
      },
      meta: %{range: normalized.range}
    }

    charts = to_contract_charts([metric_cards_chart])

    %{
      filters: %{range: normalized.range},
      charts: charts,
      metric_cards_chart: chart!(charts, "main_dashboard_metrics")
    }
  end

  defp build_charts(local_rows, benchmark_rows, labels, filters) do
    latency_points =
      metric_points(local_rows, "qa.answer.latency_ms", labels.labels)

    confidence_points =
      metric_points(local_rows, "qa.answer.confidence", labels.labels, fn v ->
        Float.round(v * 100, 2)
      end)

    {no_answer_points, _no_answer_weights} =
      ratio_points(
        local_rows,
        "qa.no_answer.count",
        "qa.question.count",
        labels.labels,
        fn ratio -> Float.round((1.0 - ratio) * 100, 2) end
      )

    benchmark_latency =
      if filters.benchmark_opt_in and benchmark_rows != [] do
        metric_points(benchmark_rows, "qa.answer.latency_ms", labels.labels)
      else
        []
      end

    time_series_benchmarks = maybe_benchmark_line("latency", benchmark_latency)

    feedback_neg = sum_metric(local_rows, "feedback.negative.count")
    feedback_total = sum_metric(local_rows, "feedback.rating")
    automation_score = strict_effectiveness_score(feedback_neg, feedback_total)

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
          %{key: "deflection", name: "Deflection", values: no_answer_points}
        ],
        summary: %{
          labels: labels.labels,
          values: %{
            "availability" => confidence_points,
            "latency" => latency_points,
            "deflection" => no_answer_points
          },
          benchmarks: time_series_benchmarks
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
          value: automation_score,
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
            %{label: "Trust", value: automation_score},
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

    ratios =
      Enum.zip(numerators, denominators)
      |> Enum.map(fn {n, d} ->
        ratio = if d <= 0, do: 0.0, else: n / d
        transform.(ratio)
      end)

    {ratios, denominators}
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

  defp sum_metric_count(rows, metric_key) do
    rows
    |> Enum.filter(&(&1.metric_key == metric_key))
    |> Enum.reduce(0, fn row, acc -> acc + row.value_count end)
  end

  defp weighted_average_metric(rows, metric_key) do
    {sum, count} =
      rows
      |> Enum.filter(&(&1.metric_key == metric_key))
      |> Enum.reduce({0.0, 0}, fn row, {sum_acc, count_acc} ->
        {sum_acc + row.value_sum, count_acc + row.value_count}
      end)

    if count > 0 do
      Float.round(sum / count, 2)
    else
      0.0
    end
  end

  defp cumulative_points(values) do
    values
    |> Enum.reduce({0.0, []}, fn value, {acc, out} ->
      amount = if is_number(value), do: value * 1.0, else: 0.0
      next = Float.round(acc + amount, 2)
      {next, [next | out]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp metric_distribution_by_dimension(rows, metric_key, dimension_key) do
    rows
    |> Enum.filter(&(&1.metric_key == metric_key))
    |> Enum.reduce(%{}, fn row, acc ->
      label =
        row
        |> Map.get(:dimensions, %{})
        |> Map.get(dimension_key, "unknown")
        |> to_string()

      Map.update(acc, label, row.value_sum, &(&1 + row.value_sum))
    end)
    |> Enum.map(fn {label, value} -> %{label: label, value: Float.round(value, 2)} end)
    |> Enum.sort_by(& &1.value, :desc)
  end

  defp confidence_distribution_axes(rows, buckets) do
    total =
      buckets
      |> Enum.map(fn {_label, key} -> sum_metric(rows, key) end)
      |> Enum.sum()

    Enum.map(buckets, fn {label, key} ->
      value = sum_metric(rows, key)
      %{label: label, value: to_percent(value, total)}
    end)
  end

  defp to_percent(_value, total) when total <= 0, do: 0.0
  defp to_percent(value, total), do: Float.round(value / total * 100, 2)

  defp apply_transform(row, transform) do
    if row.value_count <= 0 do
      0.0
    else
      transform.(Float.round(row.value_sum / row.value_count, 2))
    end
  end

  defp label_for_bucket(bucket_start, labels) do
    hour = bucket_start.hour

    cond do
      Enum.any?(labels, &String.contains?(&1, ":")) ->
        slot_hour = div(hour, 4) * 4

        [slot_hour, 0]
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
        day_slot =
          bucket_start.day
          |> Kernel.-(1)
          |> div(3)
          |> Kernel.*(3)
          |> Kernel.+(1)
          |> min(28)

        "D" <> Integer.to_string(day_slot)
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

  defp dashboard_payload(legacy_charts, filters) do
    charts = to_contract_charts(legacy_charts)

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

  defp to_contract_charts(charts) do
    Enum.map(charts, &DashboardChart.new/1)
  end

  defp latest_or_default([], default), do: default
  defp latest_or_default(values, _default), do: List.last(values)

  defp percentile_from_latency(values) do
    value = latest_or_default(values, 500.0)
    Float.round(max(0.0, min(100.0, 100.0 - value / 10.0)), 1)
  end

  defp strict_effectiveness_score(_negative, total) when total <= 0, do: 0.0

  defp strict_effectiveness_score(negative, total) do
    negative
    |> ratio_or_zero(total)
    |> then(&(1.0 - &1))
    |> Kernel.*(100.0)
    |> max(0.0)
    |> min(100.0)
    |> Float.round(1)
  end

  defp maybe_benchmark_line(_key, []), do: %{}
  defp maybe_benchmark_line(key, values), do: %{key => values}

  defp percent_change(_current, previous) when previous <= 0, do: nil

  defp percent_change(current, previous) do
    current
    |> Kernel.-(previous)
    |> ratio_or_zero(previous)
    |> Kernel.*(100.0)
    |> Float.round(2)
  end

  defp ratio_or_zero(_n, d) when d <= 0, do: 0.0
  defp ratio_or_zero(n, d), do: n / d

  # Computes weighted averages per range for time-series data.
  # For each time bucket, calculates the weighted average using the question count as weight.
  defp compute_weighted_averages_per_range(rates, weights, _labels) do
    # Calculate total weight for the entire range
    total_weight = Enum.sum(weights)

    if total_weight > 0 do
      # Compute weighted average across all buckets
      weighted_sum =
        Enum.zip(rates, weights)
        |> Enum.reduce(0.0, fn {rate, weight}, acc -> acc + rate * weight end)

      weighted_avg = Float.round(weighted_sum / total_weight, 2)

      # Return the weighted average for each bucket (consistent value across the range)
      Enum.map(rates, fn _ -> weighted_avg end)
    else
      # If no weights, return original rates
      rates
    end
  end

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

  defp window_seconds_for_range("24h"), do: 24 * 60 * 60
  defp window_seconds_for_range("7d"), do: 7 * 24 * 60 * 60
  defp window_seconds_for_range("30d"), do: 30 * 24 * 60 * 60
  defp window_seconds_for_range("90d"), do: 90 * 24 * 60 * 60
  defp window_seconds_for_range(_), do: window_seconds_for_range("7d")

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
          %{key: "deflection", name: "Deflection", values: zeroes}
        ],
        summary: %{
          labels: labels.labels,
          values: %{
            "availability" => zeroes,
            "latency" => zeroes,
            "deflection" => zeroes
          },
          benchmarks: %{}
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
