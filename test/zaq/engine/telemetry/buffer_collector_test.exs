defmodule Zaq.Engine.Telemetry.BufferCollectorTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Buffer
  alias Zaq.Engine.Telemetry.Collector
  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Repo
  alias Zaq.System, as: SystemConfig
  alias Zaq.System.Config

  setup do
    keys = [
      "telemetry.capture_infra_metrics",
      "telemetry.request_duration_threshold_ms",
      "telemetry.repo_query_duration_threshold_ms"
    ]

    if pid = Process.whereis(Buffer) do
      Sandbox.allow(Repo, self(), pid)
      Buffer.flush()
    end

    Repo.delete_all(Point)
    Repo.delete_all(from c in Config, where: c.key in ^keys)
    reload_collector_policy()

    on_exit(fn ->
      Repo.delete_all(from c in Config, where: c.key in ^keys)
      reload_collector_policy()
    end)

    :ok
  end

  test "buffer enqueue + flush persists normalized points" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert :ok =
             Buffer.enqueue(%{
               metric_key: "qa.message.count",
               value: 2,
               dimensions: %{segment: "small"},
               occurred_at: now
             })

    assert :ok = Buffer.flush()

    point = Repo.one!(from p in Point, where: p.metric_key == "qa.message.count")

    assert point.value == 2.0
    assert point.dimension_key == "segment=small"
    assert point.source == "local"
  end

  test "buffer flushes queued points on graceful shutdown" do
    name = {:global, {:telemetry_buffer_test, System.unique_integer([:positive])}}

    pid =
      start_supervised!({Buffer, name: name, flush_interval_ms: 60_000, max_batch_size: 1_000})

    Sandbox.allow(Repo, self(), pid)

    assert :ok =
             Buffer.enqueue(name, %{
               metric_key: "qa.message.count",
               value: 7,
               dimensions: %{segment: "mid"}
             })

    assert :ok = GenServer.stop(pid, :shutdown)

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "qa.message.count",
               where: fragment("?->>?", p.dimensions, "segment") == "mid",
               where: p.value == 7.0
             )
           )
  end

  test "flush/2 returns noproc error when buffer process is unavailable" do
    assert {:error, :noproc} = Buffer.flush({:global, :missing_buffer_process}, 100)
  end

  test "collector records phoenix stop events" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()

    assert Repo.exists?(from p in Point, where: p.metric_key == "phoenix.request.duration_ms")
  end

  test "record/4 keeps business metrics allowlisted" do
    assert :ok = Telemetry.record("qa.message.count", 3, %{segment: "small"})
    assert :ok = Telemetry.record("feedback.rating", 4, %{channel: "mattermost"})
    assert :ok = Telemetry.record("ingestion.documents.count", 2, %{source: "manual"})
    assert :ok = Telemetry.record("custom.metric", 10, %{})

    assert :ok = Buffer.flush()

    assert Repo.exists?(from p in Point, where: p.metric_key == "qa.message.count")
    assert Repo.exists?(from p in Point, where: p.metric_key == "feedback.rating")
    assert Repo.exists?(from p in Point, where: p.metric_key == "ingestion.documents.count")
    refute Repo.exists?(from p in Point, where: p.metric_key == "custom.metric")
  end

  test "record/4 drops infra metrics by default" do
    assert :ok = Telemetry.record("repo.query.duration_ms", 9, %{source: "users"})

    assert :ok = Buffer.flush()

    refute Repo.exists?(from p in Point, where: p.metric_key == "repo.query.duration_ms")
  end

  test "record/4 persists infra metrics when explicitly allowed" do
    assert :ok =
             Telemetry.record("repo.query.duration_ms", 9, %{source: "users"}, allow_infra: true)

    assert :ok = Buffer.flush()

    assert Repo.exists?(from p in Point, where: p.metric_key == "repo.query.duration_ms")
  end

  test "collector filters noisy routes" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: "/health"},
               %{}
             )

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()

    refute Repo.exists?(
             from(p in Point,
               where: p.metric_key == "phoenix.request.duration_ms",
               where: fragment("?->>?", p.dimensions, "route") == "/health"
             )
           )

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "phoenix.request.duration_ms",
               where: fragment("?->>?", p.dimensions, "route") == "/bo/telemetry"
             )
           )
  end

  test "collector ignores telemetry table repo query events" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:zaq, :repo, :query],
               %{total_time: Elixir.System.convert_time_unit(5, :millisecond, :native)},
               %{source: "telemetry_points"},
               %{}
             )

    assert :ok =
             Collector.handle_event(
               [:zaq, :repo, :query],
               %{total_time: Elixir.System.convert_time_unit(5, :millisecond, :native)},
               %{source: "users"},
               %{}
             )

    assert :ok = Buffer.flush()

    refute Repo.exists?(
             from(p in Point,
               where: p.metric_key == "repo.query.duration_ms",
               where: fragment("?->>?", p.dimensions, "source") == "telemetry_points"
             )
           )

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "repo.query.duration_ms",
               where: fragment("?->>?", p.dimensions, "source") == "users"
             )
           )
  end

  defp reload_collector_policy do
    if Process.whereis(Collector) do
      Collector.reload_policy()
      _ = :sys.get_state(Collector)
    end

    :ok
  end
end
