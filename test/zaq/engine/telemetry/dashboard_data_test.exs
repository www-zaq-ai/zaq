defmodule Zaq.Engine.Telemetry.DashboardDataTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Repo

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
    :ok
  end

  test "load_dashboard/1 returns standardized chart payload when rollups exist" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("qa.answer.latency_ms", now, 420.0, 1)
    insert_rollup("qa.answer.confidence", now, 0.82, 1)
    insert_rollup("qa.question.count", now, 15.0, 1)
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

  test "load_llm_performance/1 returns strict retrieval effectiveness" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("qa.question.count", now, 20.0, 20)
    insert_rollup("qa.no_answer.count", now, 4.0, 4)
    insert_rollup("qa.tokens.total", now, 1200.0, 12)
    insert_rollup("qa.tokens.prompt", now, 700.0, 12)
    insert_rollup("qa.tokens.completion", now, 500.0, 12)

    payload = Telemetry.load_llm_performance(%{range: "7d"})

    assert payload.llm_api_calls_chart.id == "llm_api_calls"
    assert payload.token_usage_chart.id == "token_usage"
    assert payload.retrieval_effectiveness_chart.id == "retrieval_effectiveness"

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
    assert get_in(payload.retrieval_effectiveness_chart, [:summary, :value]) == 100.0
  end

  defp insert_rollup(metric_key, bucket_start, sum, count) do
    Repo.insert!(%Rollup{
      metric_key: metric_key,
      bucket_start: bucket_start,
      bucket_size: "10m",
      source: "local",
      dimensions: %{},
      dimension_key: "global",
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
