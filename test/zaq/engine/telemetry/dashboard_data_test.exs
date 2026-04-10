defmodule Zaq.Engine.Telemetry.DashboardDataTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Repo
  alias Zaq.System, as: SystemConfig

  @required_dashboard_keys [
    :filters,
    :charts,
    :metrics,
    :time_series,
    :bar_chart,
    :donut_chart,
    :gauge_chart,
    :status_grid,
    :progress_countdown,
    :radar_chart
  ]

  @required_chart_ids [
    "metric_cards",
    "time_series",
    "bar",
    "donut",
    "gauge",
    "status_grid",
    "progress",
    "radar"
  ]

  setup do
    Repo.delete_all(Rollup)
    SystemConfig.set_config("telemetry.no_answer_alert_threshold_percent", "10")
    SystemConfig.set_config("telemetry.conversation_response_sla_ms", "1500")
    :ok
  end

  test "load_dashboard/1 returns standardized chart payload when rollups exist" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("qa.answer.latency_ms", now, 420.0, 1)
    insert_rollup("qa.answer.confidence", now, 0.82, 1)
    insert_rollup("qa.message.count", now, 15.0, 1)
    insert_rollup("feedback.rating", now, 12.0, 3)
    insert_rollup("feedback.negative.count", now, 2.0, 1)

    dashboard = Telemetry.load_dashboard(%{range: "7d", segment: "size", feedback_scope: "all"})

    assert_dashboard_contract(dashboard, "7d")
  end

  test "load_dashboard/1 returns canonical dashboard contract when rollups are empty" do
    dashboard = Telemetry.load_dashboard(%{range: "24h", segment: "size", feedback_scope: "all"})

    assert_dashboard_contract(dashboard, "24h")
    assert length(dashboard.charts) == length(@required_chart_ids)
    assert Enum.all?(dashboard.metrics, &Map.has_key?(&1, :value))
    assert Enum.all?(dashboard.metrics, &(&1.value in [0, 0.0]))
  end

  test "load_chart/2 returns one chart payload" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    insert_rollup("qa.answer.latency_ms", now, 390.0, 1)

    assert {:ok, chart} = Telemetry.load_chart("time_series", %{range: "24h"})
    assert chart.id == "time_series"
    assert chart.kind == :time_series
  end

  test "load_dashboard/1 only includes benchmarks when benchmark opt-in is enabled" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("qa.answer.latency_ms", now, 420.0, 1)

    Repo.insert!(%Rollup{
      metric_key: "qa.answer.latency_ms",
      bucket_start: now,
      bucket_size: "10m",
      source: "benchmark",
      dimensions: %{},
      dimension_key: Telemetry.dimension_key(%{}),
      value_sum: 390.0,
      value_count: 1,
      value_min: 390.0,
      value_max: 390.0,
      last_value: 390.0,
      last_at: now
    })

    disabled =
      Telemetry.load_dashboard(%{
        range: "7d",
        segment: "size",
        feedback_scope: "all",
        benchmark_opt_in: false
      })

    enabled =
      Telemetry.load_dashboard(%{
        range: "7d",
        segment: "size",
        feedback_scope: "all",
        benchmark_opt_in: true
      })

    assert get_in(disabled.time_series, [:summary, :benchmarks]) == %{}

    assert get_in(enabled.time_series, [:summary, :benchmarks, "latency"])
           |> Enum.max() == 390.0
  end

  test "90d range surfaces data across dashboard payloads" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("qa.answer.latency_ms", now, 420.0, 1)
    insert_rollup("qa.answer.confidence", now, 0.82, 1)
    insert_rollup("qa.message.count", now, 10.0, 10)
    insert_rollup("qa.no_answer.count", now, 2.0, 2)
    insert_rollup("qa.answer.count", now, 8.0, 8)
    insert_rollup("qa.tokens.total", now, 1200.0, 12)
    insert_rollup("qa.tokens.prompt", now, 700.0, 12)
    insert_rollup("qa.tokens.completion", now, 500.0, 12)
    insert_rollup("feedback.rating", now, 8.0, 8)
    insert_rollup("feedback.negative.count", now, 1.0, 1)
    insert_rollup("ingestion.completed.count", now, 4.0, 4)
    insert_rollup("ingestion.chunks.created", now, 20.0, 4)
    insert_rollup("ingestion.document.failed.count", now, 1.0, 1)

    dashboard = Telemetry.load_dashboard(%{range: "90d", segment: "size", feedback_scope: "all"})

    assert Enum.any?(get_in(dashboard.time_series, [:summary, :values, "latency"]), &(&1 > 0.0))

    conversations = Telemetry.load_conversations_metrics(%{range: "90d"})

    assert Enum.any?(
             get_in(conversations.no_answer_rate_chart, [:summary, :values, "no_answer_rate"]),
             &(&1 > 0.0)
           )

    llm = Telemetry.load_llm_performance(%{range: "90d"})
    assert get_in(llm.llm_api_calls_chart, [:summary, :values, "calls"]) |> Enum.sum() == 12.0

    knowledge_base = Telemetry.load_knowledge_base_metrics(%{range: "90d"})

    assert get_in(knowledge_base.ingestion_volume_chart, [:summary, :values, "documents_ingested"])
           |> Enum.sum() == 4.0
  end

  test "load_llm_performance/1 returns strict retrieval effectiveness" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("qa.message.count", now, 20.0, 20)
    insert_rollup("qa.no_answer.count", now, 4.0, 4)
    insert_rollup("qa.answer.count", now, 16.0, 16)
    insert_rollup("qa.tokens.total", now, 1200.0, 12)
    insert_rollup("qa.tokens.prompt", now, 700.0, 12)
    insert_rollup("qa.tokens.completion", now, 500.0, 12)

    payload = Telemetry.load_llm_performance(%{range: "7d"})

    assert payload.llm_api_calls_chart.id == "llm_api_calls"
    assert payload.token_usage_chart.id == "token_usage"
    assert payload.retrieval_effectiveness_chart.id == "retrieval_effectiveness"
    assert payload.token_usage_chart.series |> List.first() |> Map.get(:name) == "Output token"

    assert get_in(payload.retrieval_effectiveness_chart, [:summary, :value]) == 80.0
    assert get_in(payload.llm_api_calls_chart, [:summary, :values, "calls"]) |> Enum.sum() == 12.0

    assert get_in(payload.token_usage_chart, [:summary, :values, "input_tokens"]) |> Enum.sum() ==
             700.0

    assert get_in(payload.token_usage_chart, [:summary, :values, "output_tokens"]) |> Enum.sum() ==
             500.0
  end

  test "load_llm_performance/1 returns zero-safe payload with empty rollups" do
    payload = Telemetry.load_llm_performance(%{range: "24h"})

    assert payload.llm_api_calls_chart.id == "llm_api_calls"
    assert payload.token_usage_chart.id == "token_usage"
    assert payload.retrieval_effectiveness_chart.id == "retrieval_effectiveness"
    assert get_in(payload.retrieval_effectiveness_chart, [:summary, :value]) == 0.0
  end

  test "load_llm_performance/1 returns zero effectiveness when there are no answers" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("qa.message.count", now, 20.0, 20)
    insert_rollup("qa.no_answer.count", now, 0.0, 0)

    payload = Telemetry.load_llm_performance(%{range: "7d"})

    assert get_in(payload.retrieval_effectiveness_chart, [:summary, :value]) == 0.0
  end

  test "load_knowledge_base_metrics/1 returns ingestion and chunk metrics payload" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("ingestion.chunks.created", DateTime.add(now, -2 * 86_400, :second), 120.0, 10)

    insert_rollup(
      "ingestion.chunks.created",
      DateTime.add(now, -9 * 86_400, :second),
      100.0,
      8
    )

    insert_rollup("ingestion.completed.count", DateTime.add(now, -2 * 86_400, :second), 10.0, 10)

    insert_rollup(
      "ingestion.document.failed.count",
      DateTime.add(now, -2 * 86_400, :second),
      2.0,
      2
    )

    payload = Telemetry.load_knowledge_base_metrics(%{range: "7d"})

    assert payload.total_chunks_created_chart.id == "total_chunks_created"
    assert payload.ingestion_volume_chart.id == "ingestion_volume_over_time"
    assert payload.ingestion_success_rate_chart.id == "ingestion_success_rate"

    assert payload.average_chunks_per_document_chart.id == "average_chunks_per_document"

    total_chunks_metric =
      get_in(payload.total_chunks_created_chart, [:summary, :metrics]) |> List.first()

    average_chunks_metric =
      get_in(payload.average_chunks_per_document_chart, [:summary, :metrics]) |> List.first()

    assert total_chunks_metric.value == 120.0
    assert total_chunks_metric.trend == 20.0
    assert average_chunks_metric.value == 12.0

    assert get_in(payload.ingestion_volume_chart, [:summary, :values, "documents_ingested"])
           |> Enum.sum() ==
             10.0

    assert get_in(payload.ingestion_success_rate_chart, [:summary, :value]) == 83.33
  end

  test "load_knowledge_base_metrics/1 returns zero-safe payload with empty rollups" do
    payload = Telemetry.load_knowledge_base_metrics(%{range: "24h"})

    assert payload.total_chunks_created_chart.id == "total_chunks_created"
    assert payload.ingestion_volume_chart.id == "ingestion_volume_over_time"
    assert payload.ingestion_success_rate_chart.id == "ingestion_success_rate"
    assert payload.average_chunks_per_document_chart.id == "average_chunks_per_document"

    assert get_in(payload.total_chunks_created_chart, [:summary, :metrics])
           |> List.first()
           |> Map.get(:value) ==
             0.0

    assert get_in(payload.ingestion_success_rate_chart, [:summary, :value]) == 0.0
  end

  test "load_knowledge_base_metrics/1 falls back to ingestion.failed.count when document.failed.count is zero" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("ingestion.completed.count", now, 8.0, 8)
    # ingestion.document.failed.count is absent (sums to 0) so fallback fires
    insert_rollup("ingestion.failed.count", now, 2.0, 2)

    payload = Telemetry.load_knowledge_base_metrics(%{range: "7d"})

    # 8 completed / (8 + 2) total = 80%
    assert get_in(payload.ingestion_success_rate_chart, [:summary, :value]) == 80.0
  end

  test "load_conversations_metrics/1 returns conversations dashboard payload" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    SystemConfig.set_config("telemetry.no_answer_alert_threshold_percent", "10")
    SystemConfig.set_config("telemetry.conversation_response_sla_ms", "1500")

    insert_rollup("qa.message.count", now, 20.0, 20, dimensions: %{"channel_type" => "bo"})

    insert_rollup("qa.message.count", now, 10.0, 10,
      dimensions: %{"channel_type" => "mattermost"}
    )

    insert_rollup("qa.no_answer.count", now, 3.0, 3)
    insert_rollup("qa.answer.latency_ms", now, 1_200.0, 3)
    insert_rollup("qa.answer.confidence.bucket.gt_90", now, 3.0, 3)
    insert_rollup("qa.answer.confidence.bucket.between_80_90", now, 2.0, 2)
    insert_rollup("qa.answer.confidence.bucket.between_70_80", now, 1.0, 1)

    payload = Telemetry.load_conversations_metrics(%{range: "7d"})

    assert payload.messages_received_chart.id == "messages_received"
    assert payload.messages_per_channel_chart.id == "messages_per_channel"
    assert payload.answer_confidence_distribution_chart.id == "answer_confidence_distribution"
    assert payload.no_answer_rate_chart.id == "no_answer_rate"
    assert payload.average_response_time_chart.id == "average_response_time"

    assert get_in(payload.messages_received_chart, [:summary, :values, "messages"]) |> List.last() ==
             30.0

    assert get_in(payload.messages_per_channel_chart, [:summary, :segments]) == [
             %{label: "bo", value: 20.0},
             %{label: "mattermost", value: 10.0}
           ]

    assert get_in(payload.no_answer_rate_chart, [:summary, :baseline, :values])
           |> Enum.uniq() == [10.0]

    assert get_in(payload.no_answer_rate_chart, [:summary, :baseline, :label]) ==
             "Alert threshold"

    assert get_in(payload.average_response_time_chart, [:summary, :baseline, :values])
           |> Enum.uniq() == [1500.0]

    assert get_in(payload.average_response_time_chart, [:summary, :baseline, :label]) == "SLA"

    assert get_in(payload.answer_confidence_distribution_chart, [:summary, :axes]) == [
             %{label: "Over 90", value: 50.0},
             %{label: "80-90", value: 33.33},
             %{label: "70-80", value: 16.67},
             %{label: "50-70", value: 0.0},
             %{label: "Below 50", value: 0.0}
           ]
  end

  test "load_conversations_metrics/1 includes weights in no_answer_rate chart meta and computes per-label weighted rates" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    SystemConfig.set_config("telemetry.no_answer_alert_threshold_percent", "10")

    # Simulate scenario:
    # - Yesterday: 1 question, 1 no-answer (100%)
    # - Today, split across two chunks: 10 questions, 5 no-answers (50%)
    yesterday = DateTime.add(now, -1, :day)
    today_chunk_1 = now
    today_chunk_2 = DateTime.add(now, -2, :hour)

    insert_rollup("qa.message.count", yesterday, 1.0, 1)
    insert_rollup("qa.no_answer.count", yesterday, 1.0, 1)

    insert_rollup("qa.message.count", today_chunk_1, 6.0, 6)
    insert_rollup("qa.no_answer.count", today_chunk_1, 3.0, 3)

    insert_rollup("qa.message.count", today_chunk_2, 4.0, 4)
    insert_rollup("qa.no_answer.count", today_chunk_2, 2.0, 2)

    payload = Telemetry.load_conversations_metrics(%{range: "7d"})

    weights = get_in(payload.no_answer_rate_chart, [:meta, :weights])
    assert is_list(weights)
    assert length(weights) == 7

    non_zero_weights = Enum.filter(weights, &(&1 > 0))
    assert Enum.sort(non_zero_weights) == [1.0, 10.0]

    no_answer_rates = get_in(payload.no_answer_rate_chart, [:summary, :values, "no_answer_rate"])
    assert is_list(no_answer_rates)
    assert length(no_answer_rates) == 7

    non_zero_rates =
      Enum.zip(no_answer_rates, weights)
      |> Enum.filter(fn {_rate, weight} -> weight > 0 end)
      |> Enum.map(fn {rate, _weight} -> rate end)

    assert Enum.sort(non_zero_rates) == [50.0, 100.0]
  end

  defp insert_rollup(metric_key, bucket_start, sum, count, opts \\ []) do
    dimensions = Keyword.get(opts, :dimensions, %{})

    Repo.insert!(%Rollup{
      metric_key: metric_key,
      bucket_start: bucket_start,
      bucket_size: "10m",
      source: "local",
      dimensions: dimensions,
      dimension_key: Telemetry.dimension_key(dimensions),
      value_sum: sum,
      value_count: count,
      value_min: sum,
      value_max: sum,
      last_value: sum,
      last_at: bucket_start
    })
  end

  defp assert_dashboard_contract(dashboard, range) do
    assert Enum.all?(@required_dashboard_keys, &Map.has_key?(dashboard, &1))

    assert Enum.sort(Enum.map(dashboard.charts, & &1.id)) == Enum.sort(@required_chart_ids)

    assert Enum.all?(dashboard.charts, fn chart ->
             Enum.all?(
               [:id, :kind, :title, :labels, :series, :summary, :meta],
               &Map.has_key?(chart, &1)
             )
           end)

    assert Enum.all?(dashboard.metrics, &Map.has_key?(&1, :value))

    assert dashboard.time_series.id == "time_series"
    assert dashboard.time_series.kind == :time_series
    assert dashboard.time_series.meta.range == range

    assert Enum.all?(dashboard.bar_chart.bars, &Map.has_key?(&1, :value))
    assert Enum.all?(dashboard.donut_chart.segments, &Map.has_key?(&1, :value))
    assert Enum.all?(dashboard.radar_chart.axes, &Map.has_key?(&1, :value))

    assert Map.has_key?(dashboard.gauge_chart, :value)
    assert Map.has_key?(dashboard.gauge_chart, :max)
    assert Map.has_key?(dashboard.gauge_chart, :label)
    assert Map.has_key?(dashboard.status_grid, :items)
    assert Map.has_key?(dashboard.progress_countdown, :total)
    assert Map.has_key?(dashboard.progress_countdown, :remaining)
  end
end
