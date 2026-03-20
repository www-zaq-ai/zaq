defmodule Zaq.Engine.Telemetry.KpisTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Repo

  setup do
    Repo.delete_all(Rollup)
    :ok
  end

  test "load_main_dashboard_metrics/1 returns standardized metric cards" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("ingestion.completed.count", DateTime.add(now, -2 * 86_400, :second), 8.0, 2)
    insert_rollup("ingestion.completed.count", DateTime.add(now, -8 * 86_400, :second), 5.0, 1)

    insert_rollup("qa.tokens.total", DateTime.add(now, -2 * 86_400, :second), 1_600.0, 3)
    insert_rollup("qa.tokens.total", DateTime.add(now, -9 * 86_400, :second), 900.0, 2)

    insert_rollup("qa.tokens.total", DateTime.add(now, -1 * 86_400, :second), 2_000.0, 7,
      source: "benchmark"
    )

    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -3 * 86_400, :second), 900.0, 3)
    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -6 * 86_400, :second), 700.0, 2)

    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -2 * 86_400, :second), 99.0, 1,
      source: "benchmark"
    )

    payload = Telemetry.load_main_dashboard_metrics(%{range: "7d"})

    metrics = get_in(payload, [:metric_cards_chart, :summary, :metrics])

    docs = Enum.find(metrics, &(&1.id == "dashboard-metric-documents-ingested"))
    llm_calls = Enum.find(metrics, &(&1.id == "dashboard-metric-llm-api-calls"))
    latency = Enum.find(metrics, &(&1.id == "dashboard-metric-qa-response-time"))

    assert docs.value == 8.0
    assert llm_calls.value == 3
    assert_in_delta latency.value, 320.0, 0.0001
    assert docs.display.range == "7d"
  end

  test "load_main_dashboard_metrics/1 returns zero-safe values when no local rows match" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("ingestion.completed.count", DateTime.add(now, -40 * 86_400, :second), 12.0, 3)
    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -40 * 86_400, :second), 2_500.0, 5)

    payload = Telemetry.load_main_dashboard_metrics(%{range: "30d"})

    metrics = get_in(payload, [:metric_cards_chart, :summary, :metrics])

    assert Enum.find(metrics, &(&1.id == "dashboard-metric-documents-ingested")).value == 0.0
    assert Enum.find(metrics, &(&1.id == "dashboard-metric-qa-response-time")).value == 0.0
    assert Enum.find(metrics, &(&1.id == "dashboard-metric-llm-api-calls")).value == 0
  end

  defp insert_rollup(metric_key, bucket_start, value_sum, value_count, opts \\ []) do
    Repo.insert!(%Rollup{
      metric_key: metric_key,
      bucket_start: bucket_start,
      bucket_size: "10m",
      source: Keyword.get(opts, :source, "local"),
      dimensions: %{},
      dimension_key: "global",
      value_sum: value_sum,
      value_count: value_count,
      value_min: value_sum,
      value_max: value_sum,
      last_value: value_sum,
      last_at: bucket_start
    })
  end
end
