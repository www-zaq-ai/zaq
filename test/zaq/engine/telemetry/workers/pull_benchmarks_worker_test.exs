defmodule Zaq.Engine.Telemetry.Workers.PullBenchmarksWorkerTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.BenchmarkConnector.HTTP
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Engine.Telemetry.Workers.PullBenchmarksWorker
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.System.Config

  setup do
    Repo.delete_all(Rollup)

    Repo.delete_all(
      from c in Config,
        where:
          c.key in ["telemetry.pull_cursor", "telemetry.enabled", "telemetry.benchmark_opt_in"]
    )

    original = Application.get_env(:zaq, Telemetry, [])

    Application.put_env(
      :zaq,
      Telemetry,
      Keyword.merge(original, req_options: [plug: {Req.Test, HTTP}])
    )

    on_exit(fn -> Application.put_env(:zaq, Telemetry, original) end)

    :ok
  end

  test "perform/1 pulls benchmark rollups and updates cursor" do
    assert {:ok, _} = System.set_config("telemetry.enabled", "true")
    assert {:ok, _} = System.set_config("telemetry.benchmark_opt_in", "true")

    cursor = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Req.Test.stub(HTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/telemetry/benchmarks"

      Req.Test.json(conn, %{
        "cursor" => DateTime.to_iso8601(cursor),
        "rollups" => [
          %{
            "metric_key" => "qa.answer.latency_ms",
            "bucket_start" => DateTime.to_iso8601(DateTime.add(cursor, -600, :second)),
            "bucket_size" => "10m",
            "dimensions" => %{"size" => "small"},
            "value_sum" => 900.0,
            "value_count" => 3,
            "value_min" => 200.0,
            "value_max" => 400.0,
            "last_value" => 300.0,
            "last_at" => DateTime.to_iso8601(cursor)
          }
        ]
      })
    end)

    assert :ok = PullBenchmarksWorker.perform(%{})

    assert Repo.exists?(from r in Rollup, where: r.source == "benchmark")

    assert %DateTime{} = stored_cursor = Telemetry.get_cursor("telemetry.pull_cursor")
    assert DateTime.compare(stored_cursor, cursor) == :eq
  end

  test "perform/1 is a no-op when telemetry is disabled" do
    assert {:ok, _} = System.set_config("telemetry.enabled", "false")
    assert {:ok, _} = System.set_config("telemetry.benchmark_opt_in", "true")

    Req.Test.stub(HTTP, fn _conn ->
      flunk("remote API should not be called when telemetry is disabled")
    end)

    assert :ok = PullBenchmarksWorker.perform(%{})
  end

  test "perform/1 is a no-op when benchmark opt-in is disabled" do
    assert {:ok, _} = System.set_config("telemetry.enabled", "true")
    assert {:ok, _} = System.set_config("telemetry.benchmark_opt_in", "false")

    Req.Test.stub(HTTP, fn _conn ->
      flunk("remote API should not be called when benchmark opt-in is disabled")
    end)

    assert :ok = PullBenchmarksWorker.perform(%{})
  end

  test "perform/1 falls back to row last_at values when response cursor is missing" do
    assert {:ok, _} = System.set_config("telemetry.enabled", "true")
    assert {:ok, _} = System.set_config("telemetry.benchmark_opt_in", "true")

    newest = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    older = DateTime.add(newest, -120, :second)

    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{
        "rollups" => [
          %{
            "metric_key" => "qa.answer.latency_ms",
            "bucket_start" => DateTime.to_iso8601(DateTime.add(newest, -600, :second)),
            "bucket_size" => "10m",
            "dimensions" => %{"size" => "small"},
            "value_sum" => 900.0,
            "value_count" => 3,
            "value_min" => 200.0,
            "value_max" => 400.0,
            "last_value" => 300.0,
            "last_at" => DateTime.to_iso8601(older)
          },
          %{
            "metric_key" => "qa.answer.latency_ms",
            "bucket_start" => DateTime.to_iso8601(DateTime.add(newest, -300, :second)),
            "bucket_size" => "10m",
            "dimensions" => %{"size" => "medium"},
            "value_sum" => 1100.0,
            "value_count" => 4,
            "value_min" => 200.0,
            "value_max" => 500.0,
            "last_value" => 350.0,
            "last_at" => DateTime.to_iso8601(newest)
          },
          %{
            "metric_key" => "qa.answer.latency_ms",
            "bucket_start" => DateTime.to_iso8601(DateTime.add(newest, -200, :second)),
            "bucket_size" => "10m",
            "dimensions" => %{"size" => "invalid"},
            "value_sum" => 100.0,
            "value_count" => 1,
            "value_min" => 100.0,
            "value_max" => 100.0,
            "last_value" => 100.0,
            "last_at" => "not-an-iso8601"
          }
        ]
      })
    end)

    assert :ok = PullBenchmarksWorker.perform(%{})

    assert %DateTime{} = stored_cursor = Telemetry.get_cursor("telemetry.pull_cursor")
    assert DateTime.compare(stored_cursor, newest) == :eq
  end

  test "perform/1 keeps cursor unchanged when fallback rows have no valid last_at" do
    assert {:ok, _} = System.set_config("telemetry.enabled", "true")
    assert {:ok, _} = System.set_config("telemetry.benchmark_opt_in", "true")

    existing_cursor = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, _} = Telemetry.put_cursor("telemetry.pull_cursor", existing_cursor)

    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{
        "cursor" => 12,
        "rollups" => [
          %{
            "metric_key" => "qa.answer.latency_ms",
            "bucket_start" => DateTime.to_iso8601(DateTime.add(existing_cursor, -600, :second)),
            "bucket_size" => "10m",
            "dimensions" => %{"size" => "small"},
            "value_sum" => 900.0,
            "value_count" => 3,
            "value_min" => 200.0,
            "value_max" => 400.0,
            "last_value" => 300.0,
            "last_at" => nil
          },
          %{
            "metric_key" => "qa.answer.latency_ms",
            "bucket_start" => DateTime.to_iso8601(DateTime.add(existing_cursor, -300, :second)),
            "bucket_size" => "10m",
            "dimensions" => %{"size" => "medium"},
            "value_sum" => 1100.0,
            "value_count" => 4,
            "value_min" => 200.0,
            "value_max" => 500.0,
            "last_value" => 350.0,
            "last_at" => "still-bad"
          },
          %{
            "metric_key" => "qa.answer.latency_ms",
            "bucket_start" => DateTime.to_iso8601(DateTime.add(existing_cursor, -200, :second)),
            "bucket_size" => "10m",
            "dimensions" => %{"size" => "invalid"},
            "value_sum" => 100.0,
            "value_count" => 1,
            "value_min" => 100.0,
            "value_max" => 100.0,
            "last_value" => 100.0,
            "last_at" => "bad"
          }
        ]
      })
    end)

    assert :ok = PullBenchmarksWorker.perform(%{})
    assert DateTime.compare(Telemetry.get_cursor("telemetry.pull_cursor"), existing_cursor) == :eq
  end
end
