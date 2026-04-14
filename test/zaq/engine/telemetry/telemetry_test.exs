defmodule Zaq.Engine.TelemetryTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Buffer
  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Repo
  alias Zaq.System, as: SystemConfig
  alias Zaq.System.Config

  setup do
    if pid = Process.whereis(Buffer) do
      Sandbox.allow(Repo, self(), pid)
      Buffer.flush()
    end

    Repo.delete_all(Point)
    Repo.delete_all(Rollup)
    Repo.delete_all(from c in Config, where: like(c.key, "telemetry.%"))

    previous_remote_url = Elixir.System.get_env("TELEMETRY_REMOTE_URL")
    previous_remote_token = Elixir.System.get_env("TELEMETRY_REMOTE_TOKEN")
    Elixir.System.delete_env("TELEMETRY_REMOTE_URL")
    Elixir.System.delete_env("TELEMETRY_REMOTE_TOKEN")

    original_telemetry_env = Application.get_env(:zaq, Telemetry, [])

    on_exit(fn ->
      Repo.delete_all(Point)
      Repo.delete_all(Rollup)
      Repo.delete_all(from c in Config, where: like(c.key, "telemetry.%"))

      if pid = Process.whereis(Buffer) do
        Sandbox.allow(Repo, self(), pid)
        Buffer.flush()
      end

      restore_env("TELEMETRY_REMOTE_URL", previous_remote_url)
      restore_env("TELEMETRY_REMOTE_TOKEN", previous_remote_token)
      Application.put_env(:zaq, Telemetry, original_telemetry_env)
    end)

    :ok
  end

  test "record/4 enforces guards and persistence allowlist rules" do
    assert :ok = Telemetry.record("qa.message.count", "not-a-number", %{segment: "small"})
    assert :ok = Telemetry.record(:qa_message_count, 3, %{segment: "small"})

    assert :ok =
             Telemetry.record("qa.message.count", 3, %{
               segment: :small,
               healthy: true,
               meta: %{x: 1}
             })

    assert :ok = Telemetry.record("repo.query.duration_ms", 9, %{source: "users"})

    assert :ok =
             Telemetry.record("repo.query.duration_ms", 9, %{source: "users"}, allow_infra: true)

    assert :ok = Telemetry.record("custom.metric", 1, %{anything: "goes"})
    assert :ok = Telemetry.record("qa.non_map_dimensions", 1, "invalid")

    assert :ok = Buffer.flush()

    persisted = Repo.all(from p in Point, order_by: [asc: p.metric_key])
    metric_keys = Enum.map(persisted, & &1.metric_key)

    assert metric_keys == ["qa.message.count", "qa.non_map_dimensions", "repo.query.duration_ms"]

    qa_point = Enum.find(persisted, &(&1.metric_key == "qa.message.count"))
    assert qa_point.dimensions["segment"] == "small"
    assert qa_point.dimensions["healthy"] == "true"
    assert qa_point.dimensions["meta"] == "%{x: 1}"

    non_map_dims_point = Enum.find(persisted, &(&1.metric_key == "qa.non_map_dimensions"))
    assert non_map_dims_point.dimensions == %{}
  end

  test "record_feedback/3 normalizes reasons and only emits negatives for low ratings" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert :ok =
             Telemetry.record_feedback(
               1,
               %{feedback_reasons: " Too slow,Outdated, Too slow, ", user_id: 7, channel: :chat},
               occurred_at: occurred_at
             )

    assert :ok =
             Telemetry.record_feedback(
               5,
               %{feedback_reasons: [:should_not_be_recorded], user_id: 11},
               occurred_at: occurred_at
             )

    assert :ok = Buffer.flush()

    assert Repo.aggregate(from(p in Point, where: p.metric_key == "feedback.rating"), :count, :id) ==
             2

    assert Repo.aggregate(
             from(p in Point, where: p.metric_key == "feedback.negative.count"),
             :count,
             :id
           ) ==
             1

    reasons =
      Repo.all(
        from p in Point,
          where: p.metric_key == "feedback.negative.reason.count",
          select: fragment("?->>?", p.dimensions, "feedback_reason")
      )

    assert Enum.sort(reasons) == ["Outdated", "Too slow"]

    rating_point =
      Repo.one!(
        from p in Point,
          where: p.metric_key == "feedback.rating",
          where: fragment("?->>?", p.dimensions, "user_id") == "7"
      )

    refute Map.has_key?(rating_point.dimensions, "feedback_reasons")
    assert rating_point.dimensions["channel"] == "chat"
  end

  test "record_feedback/3 ignores invalid feedback_reasons values" do
    assert :ok = Telemetry.record_feedback(2, %{feedback_reasons: 123, source: :chat})
    assert :ok = Buffer.flush()

    assert Repo.aggregate(
             from(p in Point, where: p.metric_key == "feedback.negative.reason.count"),
             :count,
             :id
           ) ==
             0

    assert Repo.exists?(
             from p in Point,
               where: p.metric_key == "feedback.negative.count",
               where: fragment("?->>?", p.dimensions, "source") == "chat"
           )
  end

  test "list_recent_points/1 parses defaults and supports wildcard metric filtering" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_point("qa.message.count", DateTime.add(now, -60, :second), 1.0)
    insert_point("feedback.rating", DateTime.add(now, -120, :second), 4.0)
    insert_point("qa.message.old", DateTime.add(now, -6 * 60, :second), 1.0)

    qa_recent =
      Telemetry.list_recent_points(%{
        "metric" => "qa.*",
        "limit" => "not-an-int",
        "last_minutes" => "invalid"
      })

    assert Enum.map(qa_recent, & &1.metric_key) == ["qa.message.count"]

    feedback_recent =
      Telemetry.list_recent_points(%{"metric" => "feedback.*", "last_minutes" => "10"})

    assert Enum.map(feedback_recent, & &1.metric_key) == ["feedback.rating"]

    limited = Telemetry.list_recent_points(%{"limit" => 1, "last_minutes" => 10})
    assert length(limited) == 1
    assert hd(limited).metric_key == "qa.message.count"
  end

  test "list_local_rollups_since/2 filters by cursor, source and limit" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old_local =
      insert_rollup("qa.answer.latency_ms", DateTime.add(now, -1_200, :second), 100.0, 1)

    new_local =
      insert_rollup("qa.answer.latency_ms", DateTime.add(now, -600, :second), 200.0, 2,
        updated_at: DateTime.add(now, -30, :second)
      )

    insert_rollup("qa.answer.latency_ms", DateTime.add(now, -300, :second), 300.0, 3,
      source: "benchmark"
    )

    assert [recent] = Telemetry.list_local_rollups_since(old_local.updated_at)
    assert recent.id == new_local.id

    assert [first_only] = Telemetry.list_local_rollups_since(nil, 1)
    assert first_only.id == old_local.id
  end

  test "upsert_benchmark_rollups/1 converts values and updates on conflict" do
    bucket_start =
      DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:microsecond)

    rows = [
      %{
        "metric_key" => "qa.answer.latency_ms",
        "bucket_start" => DateTime.to_iso8601(bucket_start),
        "dimensions" => %{"region" => "eu", :size => "small"},
        "value_sum" => "120.5",
        "value_count" => "3",
        "value_min" => 10,
        "value_max" => "40.2ms",
        "last_value" => :invalid,
        "last_at" => "invalid"
      }
    ]

    assert {1, nil} = Telemetry.upsert_benchmark_rollups(rows)

    row = Repo.one!(from r in Rollup, where: r.source == "benchmark")
    assert row.bucket_size == "10m"
    assert row.value_sum == 120.5
    assert row.value_count == 3
    assert row.value_min == 10.0
    assert row.value_max == 40.2
    assert row.last_value == 0.0
    assert row.dimension_key == "region=eu|size=small"

    assert {1, nil} =
             Telemetry.upsert_benchmark_rollups([
               %{
                 metric_key: "qa.answer.latency_ms",
                 bucket_start: DateTime.to_iso8601(bucket_start),
                 bucket_size: "10m",
                 dimensions: %{size: "small", region: "eu"},
                 value_sum: "301.0",
                 value_count: 7,
                 value_min: "12.1",
                 value_max: "99.9",
                 last_value: 51,
                 last_at: DateTime.to_iso8601(bucket_start)
               }
             ])

    assert Repo.aggregate(from(r in Rollup, where: r.source == "benchmark"), :count, :id) == 1

    updated = Repo.one!(from r in Rollup, where: r.source == "benchmark")
    assert updated.value_sum == 301.0
    assert updated.value_count == 7
    assert updated.value_min == 12.1
    assert updated.value_max == 99.9
    assert updated.last_value == 51.0
  end

  test "config helpers read defaults and stored values" do
    assert Telemetry.telemetry_enabled?()
    refute Telemetry.benchmark_opt_in?()
    refute Telemetry.capture_infra_metrics?()

    assert {:ok, _} = SystemConfig.set_config("telemetry.enabled", false)
    assert {:ok, _} = SystemConfig.set_config("telemetry.benchmark_opt_in", 1)
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)

    refute Telemetry.telemetry_enabled?()
    assert Telemetry.benchmark_opt_in?()
    assert Telemetry.capture_infra_metrics?()

    assert Telemetry.dimension_key(%{}) == "global"
    assert Telemetry.dimension_key(%{b: 2, a: :x, enabled: true}) == "a=x|b=2|enabled=true"

    assert Telemetry.get_cursor("telemetry.push_cursor") == nil
    assert Telemetry.get_cursor_id("telemetry.pull_cursor_id") == 0

    cursor = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, _} = Telemetry.put_cursor("telemetry.push_cursor", cursor)
    assert {:ok, _} = Telemetry.put_cursor_id("telemetry.pull_cursor_id", 42)

    assert %DateTime{} = stored_cursor = Telemetry.get_cursor("telemetry.push_cursor")
    assert DateTime.compare(stored_cursor, cursor) == :eq
    assert Telemetry.get_cursor_id("telemetry.pull_cursor_id") == 42

    assert {:ok, _} = SystemConfig.set_config("telemetry.pull_cursor_id", "invalid")
    assert {:ok, _} = SystemConfig.set_config("telemetry.push_cursor", "not-a-date")
    assert Telemetry.get_cursor("telemetry.push_cursor") == nil
    assert Telemetry.get_cursor_id("telemetry.pull_cursor_id") == 0

    assert Telemetry.organization_profile() == %{
             org_id: nil,
             size: "unknown",
             geography: "unknown",
             industry: "unknown"
           }

    assert {:ok, _} = SystemConfig.set_config("telemetry.org_id", "org-1")
    assert {:ok, _} = SystemConfig.set_config("telemetry.org_size", "51-250")
    assert {:ok, _} = SystemConfig.set_config("telemetry.geography", "eu")
    assert {:ok, _} = SystemConfig.set_config("telemetry.industry", "tech")

    assert Telemetry.organization_profile() == %{
             org_id: "org-1",
             size: "51-250",
             geography: "eu",
             industry: "tech"
           }
  end

  test "remote_url/0, remote_token/0 and req_options/0 follow precedence" do
    assert Telemetry.remote_url() == "https://telemetry.zaq.ai"
    assert Telemetry.remote_token() == ""

    Elixir.System.put_env("TELEMETRY_REMOTE_URL", "https://env.example")
    Elixir.System.put_env("TELEMETRY_REMOTE_TOKEN", "env-token")

    assert Telemetry.remote_url() == "https://env.example"
    assert Telemetry.remote_token() == "env-token"

    assert {:ok, _} = SystemConfig.set_config("telemetry.remote_url", "https://config.example")
    assert {:ok, _} = SystemConfig.set_config("telemetry.remote_token", "config-token")

    assert Telemetry.remote_url() == "https://config.example"
    assert Telemetry.remote_token() == "env-token"

    Elixir.System.delete_env("TELEMETRY_REMOTE_TOKEN")
    assert Telemetry.remote_token() == "config-token"

    original = Application.get_env(:zaq, Telemetry, [])

    Application.put_env(
      :zaq,
      Telemetry,
      Keyword.merge(original, req_options: [receive_timeout: 99])
    )

    assert Telemetry.req_options() == [receive_timeout: 99]
  end

  test "dashboard delegates and telemetry threshold helpers expose normalized config" do
    assert is_map(Telemetry.load_dashboard(%{range: "7d"}))
    assert is_map(Telemetry.load_llm_performance(%{range: "30d"}))
    assert is_map(Telemetry.load_conversations_metrics(%{range: "30d"}))
    assert is_map(Telemetry.load_knowledge_base_metrics(%{range: "30d"}))
    assert is_map(Telemetry.load_main_dashboard_metrics(%{range: "30d"}))
    assert {:error, :unknown_chart} = Telemetry.load_chart("unknown-chart", %{range: "30d"})

    assert Telemetry.request_duration_threshold_ms() == 10
    assert Telemetry.repo_query_duration_threshold_ms() == 5
    assert Telemetry.no_answer_alert_threshold_percent() == 10
    assert Telemetry.conversation_response_sla_ms() == 1500

    assert {:ok, _} = SystemConfig.set_config("telemetry.request_duration_threshold_ms", 77)
    assert {:ok, _} = SystemConfig.set_config("telemetry.repo_query_duration_threshold_ms", 33)
    assert {:ok, _} = SystemConfig.set_config("telemetry.no_answer_alert_threshold_percent", 25)
    assert {:ok, _} = SystemConfig.set_config("telemetry.conversation_response_sla_ms", 2200)

    assert Telemetry.request_duration_threshold_ms() == 77
    assert Telemetry.repo_query_duration_threshold_ms() == 33
    assert Telemetry.no_answer_alert_threshold_percent() == 25
    assert Telemetry.conversation_response_sla_ms() == 2200
  end

  test "dashboard_kpis/1 maps day params to range buckets and defaults" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_dashboard_rollup(
      "ingestion.completed.count",
      DateTime.add(now, -12 * 3_600, :second),
      5.0,
      1
    )

    insert_dashboard_rollup("qa.tokens.total", DateTime.add(now, -12 * 3_600, :second), 20.0, 2)

    insert_dashboard_rollup(
      "qa.answer.latency_ms",
      DateTime.add(now, -12 * 3_600, :second),
      200.0,
      2
    )

    insert_dashboard_rollup(
      "ingestion.completed.count",
      DateTime.add(now, -3 * 86_400, :second),
      7.0,
      1
    )

    insert_dashboard_rollup("qa.tokens.total", DateTime.add(now, -3 * 86_400, :second), 30.0, 3)

    insert_dashboard_rollup(
      "qa.answer.latency_ms",
      DateTime.add(now, -3 * 86_400, :second),
      900.0,
      3
    )

    insert_dashboard_rollup(
      "ingestion.completed.count",
      DateTime.add(now, -20 * 86_400, :second),
      11.0,
      1
    )

    insert_dashboard_rollup("qa.tokens.total", DateTime.add(now, -20 * 86_400, :second), 40.0, 4)

    insert_dashboard_rollup(
      "qa.answer.latency_ms",
      DateTime.add(now, -20 * 86_400, :second),
      2_000.0,
      4
    )

    insert_dashboard_rollup(
      "ingestion.completed.count",
      DateTime.add(now, -60 * 86_400, :second),
      13.0,
      1
    )

    insert_dashboard_rollup("qa.tokens.total", DateTime.add(now, -60 * 86_400, :second), 50.0, 5)

    insert_dashboard_rollup(
      "qa.answer.latency_ms",
      DateTime.add(now, -60 * 86_400, :second),
      3_500.0,
      5
    )

    day_1 = Telemetry.dashboard_kpis(days: 1)
    assert day_1.documents_ingested_30d == 5.0
    assert day_1.llm_api_calls_30d == 2
    assert_in_delta day_1.qa_avg_response_ms_30d, 100.0, 0.0001

    day_7 = Telemetry.dashboard_kpis(%{days: 7})
    assert day_7.documents_ingested_30d == 12.0
    assert day_7.llm_api_calls_30d == 5
    assert_in_delta day_7.qa_avg_response_ms_30d, 220.0, 0.0001

    default_range = Telemetry.dashboard_kpis("invalid")
    default_explicit = Telemetry.dashboard_kpis(30)
    assert default_range.documents_ingested_30d == default_explicit.documents_ingested_30d
    assert default_range.llm_api_calls_30d == default_explicit.llm_api_calls_30d

    assert_in_delta default_range.qa_avg_response_ms_30d,
                    default_explicit.qa_avg_response_ms_30d,
                    0.0001

    assert default_explicit.documents_ingested_30d == 23.0
    assert default_explicit.llm_api_calls_30d == 9

    day_90 = Telemetry.dashboard_kpis(120)
    assert day_90.documents_ingested_30d == 36.0
    assert day_90.llm_api_calls_30d == 14
    assert_in_delta day_90.qa_avg_response_ms_30d, 471.428571, 0.01
  end

  defp insert_point(metric_key, occurred_at, value) do
    Repo.insert!(%Point{
      metric_key: metric_key,
      occurred_at: occurred_at,
      value: value,
      dimensions: %{},
      dimension_key: "global",
      source: "local"
    })
  end

  defp insert_rollup(metric_key, bucket_start, value_sum, value_count, opts \\ []) do
    updated_at = Keyword.get(opts, :updated_at, bucket_start)
    source = Keyword.get(opts, :source, "local")
    dimensions = Keyword.get(opts, :dimensions, %{})

    Repo.insert!(%Rollup{
      metric_key: metric_key,
      bucket_start: bucket_start,
      bucket_size: Keyword.get(opts, :bucket_size, "10m"),
      source: source,
      dimensions: dimensions,
      dimension_key: Telemetry.dimension_key(dimensions),
      value_sum: value_sum,
      value_count: value_count,
      value_min: value_sum,
      value_max: value_sum,
      last_value: value_sum,
      last_at: bucket_start,
      inserted_at: bucket_start,
      updated_at: updated_at
    })
  end

  defp insert_dashboard_rollup(metric_key, bucket_start, value_sum, value_count) do
    insert_rollup(metric_key, bucket_start, value_sum, value_count,
      source: "local",
      dimensions: %{}
    )
  end

  defp restore_env(key, nil), do: Elixir.System.delete_env(key)
  defp restore_env(key, value), do: Elixir.System.put_env(key, value)
end
