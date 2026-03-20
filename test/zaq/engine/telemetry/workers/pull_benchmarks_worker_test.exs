defmodule Zaq.Engine.Telemetry.Workers.PullBenchmarksWorkerTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.BenchmarkConnector.HTTP
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Engine.Telemetry.Workers.PullBenchmarksWorker
  alias Zaq.Repo
  alias Zaq.System

  setup do
    Repo.delete_all(Rollup)

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
end
