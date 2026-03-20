defmodule Zaq.Engine.Telemetry.KpisTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Repo

  setup do
    Repo.delete_all(Rollup)
    :ok
  end

  test "dashboard_kpis/1 returns weighted KPI aggregates for local rollups" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("ingestion.completed.count", DateTime.add(now, -2 * 86_400, :second), 8.0, 2)
    insert_rollup("ingestion.completed.count", DateTime.add(now, -8 * 86_400, :second), 5.0, 1)

    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -3 * 86_400, :second), 900.0, 3)
    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -6 * 86_400, :second), 700.0, 2)

    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -2 * 86_400, :second), 99.0, 1,
      source: "benchmark"
    )

    kpis = Telemetry.dashboard_kpis(%{days: 7})

    assert kpis.documents_ingested_30d == 8.0
    assert_in_delta kpis.qa_avg_response_ms_30d, 320.0, 0.0001
    assert kpis.llm_api_calls_30d == 0
  end

  test "dashboard_kpis/1 defaults to 30 days and returns zeros when no local rows match" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_rollup("ingestion.completed.count", DateTime.add(now, -40 * 86_400, :second), 12.0, 3)
    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -40 * 86_400, :second), 2_500.0, 5)

    kpis = Telemetry.dashboard_kpis([])

    assert kpis.documents_ingested_30d == 0.0
    assert kpis.qa_avg_response_ms_30d == 0.0
    assert kpis.llm_api_calls_30d == 0
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
