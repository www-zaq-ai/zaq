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

  test "record_feedback/3 records negative reason points with canonical dimensions and occurred_at" do
    occurred_at = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:microsecond)

    assert :ok =
             Telemetry.record_feedback(
               1,
               %{
                 user_id: "42",
                 feedback_reasons: ["Too slow", "Outdated information"]
               },
               occurred_at: occurred_at
             )

    assert :ok = Buffer.flush()

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "feedback.negative.count",
               where: p.occurred_at == ^occurred_at
             )
           )

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "feedback.negative.reason.count",
               where: fragment("?->>?", p.dimensions, "feedback_reason") == "Too slow"
             )
           )

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "feedback.negative.reason.count",
               where:
                 fragment("?->>?", p.dimensions, "feedback_reason") ==
                   "Outdated information"
             )
           )
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

  test "collector ignores phoenix stop events below duration threshold" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    assert {:ok, _} = SystemConfig.set_config("telemetry.request_duration_threshold_ms", 300)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()
    refute Repo.exists?(from p in Point, where: p.metric_key == "phoenix.request.duration_ms")
  end

  test "collector ignores phoenix stop events with noisy prefix route" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: "/assets/app.js"},
               %{}
             )

    assert :ok = Buffer.flush()

    refute Repo.exists?(
             from(p in Point,
               where: p.metric_key == "phoenix.request.duration_ms",
               where: fragment("?->>?", p.dimensions, "route") == "/assets/app.js"
             )
           )
  end

  test "collector records phoenix stop with unknown route when route is nil" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    assert {:ok, _} = SystemConfig.set_config("telemetry.request_duration_threshold_ms", 10)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: nil},
               %{}
             )

    assert :ok = Buffer.flush()

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "phoenix.request.duration_ms",
               where: fragment("?->>?", p.dimensions, "route") == "unknown"
             )
           )
  end

  test "collector records phoenix exception events" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    assert {:ok, _} = SystemConfig.set_config("telemetry.request_duration_threshold_ms", 10)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :exception],
               %{duration: Elixir.System.convert_time_unit(120, :millisecond, :native)},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "phoenix.request.exception_ms",
               where: fragment("?->>?", p.dimensions, "route") == "/bo/telemetry"
             )
           )
  end

  test "collector infra events return ok and persist nothing when infra capture disabled" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", false)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok =
             Collector.handle_event(
               [:zaq, :repo, :query],
               %{total_time: Elixir.System.convert_time_unit(25, :millisecond, :native)},
               %{source: "users"},
               %{}
             )

    assert :ok =
             Collector.handle_event(
               [:oban, :job, :stop],
               %{duration: Elixir.System.convert_time_unit(90, :millisecond, :native)},
               %{job: %{queue: "default", worker: "Jobs.Worker"}, state: :success},
               %{}
             )

    assert :ok = Buffer.flush()
    assert Repo.aggregate(Point, :count, :id) == 0
  end

  test "collector ignores repo query when source is unknown" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:zaq, :repo, :query],
               %{total_time: Elixir.System.convert_time_unit(25, :millisecond, :native)},
               %{source: nil},
               %{}
             )

    assert :ok = Buffer.flush()
    refute Repo.exists?(from p in Point, where: p.metric_key == "repo.query.duration_ms")
  end

  test "collector ignores repo query when duration is non-positive" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:zaq, :repo, :query],
               %{total_time: 0},
               %{source: "users"},
               %{}
             )

    assert :ok = Buffer.flush()
    refute Repo.exists?(from p in Point, where: p.metric_key == "repo.query.duration_ms")
  end

  test "collector ignores repo query below threshold" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    assert {:ok, _} = SystemConfig.set_config("telemetry.repo_query_duration_threshold_ms", 50)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:zaq, :repo, :query],
               %{total_time: Elixir.System.convert_time_unit(25, :millisecond, :native)},
               %{source: "users"},
               %{}
             )

    assert :ok = Buffer.flush()
    refute Repo.exists?(from p in Point, where: p.metric_key == "repo.query.duration_ms")
  end

  test "collector records oban stop dimensions" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:oban, :job, :stop],
               %{duration: Elixir.System.convert_time_unit(90, :millisecond, :native)},
               %{job: %{queue: "default", worker: "Jobs.Worker"}, state: :success},
               %{}
             )

    assert :ok = Buffer.flush()

    assert Repo.exists?(
             from(p in Point,
               where: p.metric_key == "oban.job.duration_ms",
               where: fragment("?->>?", p.dimensions, "queue") == "default",
               where: fragment("?->>?", p.dimensions, "worker") == "Jobs.Worker",
               where: fragment("?->>?", p.dimensions, "state") == "success"
             )
           )
  end

  test "collector records oban exception count" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:oban, :job, :exception],
               %{},
               %{job: %{queue: "default", worker: "Jobs.Worker"}, state: :failure},
               %{}
             )

    assert :ok = Buffer.flush()

    point = Repo.one!(from p in Point, where: p.metric_key == "oban.job.exception.count")
    assert point.value == 1.0
  end

  test "collector unknown event returns ok and persists nothing" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:unknown, :event],
               %{duration: 99},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()
    assert Repo.aggregate(Point, :count, :id) == 0
  end

  test "collector native_ms accepts float durations" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    assert {:ok, _} = SystemConfig.set_config("telemetry.request_duration_threshold_ms", 10)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: 15.5},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()

    point = Repo.one!(from p in Point, where: p.metric_key == "phoenix.request.duration_ms")
    assert point.value == 15.5
  end

  test "collector native_ms fallback for invalid duration does not persist below threshold" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", true)
    assert {:ok, _} = SystemConfig.set_config("telemetry.request_duration_threshold_ms", 1)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: nil},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()
    refute Repo.exists?(from p in Point, where: p.metric_key == "phoenix.request.duration_ms")
  end

  test "collector reload_policy updates behavior after config change" do
    assert {:ok, _} = SystemConfig.set_config("telemetry.capture_infra_metrics", false)
    reload_collector_policy()

    assert :ok =
             Collector.handle_event(
               [:phoenix, :router_dispatch, :stop],
               %{duration: Elixir.System.convert_time_unit(250, :millisecond, :native)},
               %{route: "/bo/telemetry"},
               %{}
             )

    assert :ok = Buffer.flush()
    assert Repo.aggregate(Point, :count, :id) == 0

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

  test "buffer auto flushes when max batch size is reached" do
    name = {:global, {:telemetry_buffer_test, System.unique_integer([:positive])}}

    pid =
      start_supervised!({Buffer, name: name, flush_interval_ms: 60_000, max_batch_size: 2})

    Sandbox.allow(Repo, self(), pid)

    assert :ok =
             Buffer.enqueue(name, %{
               metric_key: "qa.message.count",
               value: 1,
               dimensions: %{segment: "a"}
             })

    assert :ok =
             Buffer.enqueue(name, %{
               metric_key: "qa.message.count",
               value: 2,
               dimensions: %{segment: "b"}
             })

    assert_eventually(fn ->
      Repo.aggregate(from(p in Point, where: p.metric_key == "qa.message.count"), :count, :id) ==
        2
    end)
  end

  test "buffer timer flush persists queued points" do
    name = {:global, {:telemetry_buffer_test, System.unique_integer([:positive])}}

    pid =
      start_supervised!({Buffer, name: name, flush_interval_ms: 25, max_batch_size: 1_000})

    Sandbox.allow(Repo, self(), pid)

    assert :ok =
             Buffer.enqueue(name, %{
               metric_key: "qa.message.count",
               value: 9,
               dimensions: %{segment: "timer"}
             })

    assert_eventually(fn ->
      Repo.exists?(
        from(p in Point,
          where: p.metric_key == "qa.message.count",
          where: fragment("?->>?", p.dimensions, "segment") == "timer"
        )
      )
    end)
  end

  test "flush/2 returns timeout when target process does not reply" do
    pid =
      spawn(fn ->
        receive do
        end
      end)

    assert {:error, :timeout} = Buffer.flush(pid, 20)
  end

  test "flush/2 returns generic exit reason when target crashes during call" do
    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, :flush} -> exit(:boom)
        end
      end)

    assert {:error, {:boom, {GenServer, :call, [^pid, :flush, 100]}}} = Buffer.flush(pid, 100)
  end

  test "buffer flush rescue keeps points in state after insert failure" do
    name = {:global, {:telemetry_buffer_test, System.unique_integer([:positive])}}

    pid =
      start_supervised!({Buffer, name: name, flush_interval_ms: 60_000, max_batch_size: 1_000})

    Sandbox.allow(Repo, self(), pid)

    assert :ok =
             Buffer.enqueue(name, %{
               metric_key: "qa.message.count",
               value: 1,
               occurred_at: "not-a-datetime",
               dimensions: %{segment: "broken"}
             })

    assert :ok = Buffer.flush(name)

    state = :sys.get_state(pid)
    assert length(state.points) == 1

    refute Repo.exists?(
             from(p in Point,
               where: p.metric_key == "qa.message.count",
               where: fragment("?->>?", p.dimensions, "segment") == "broken"
             )
           )
  end

  test "buffer terminate safe flush rescue handles corrupted state" do
    name = {:global, {:telemetry_buffer_test, System.unique_integer([:positive])}}

    pid =
      start_supervised!({Buffer, name: name, flush_interval_ms: 60_000, max_batch_size: 1_000})

    Sandbox.allow(Repo, self(), pid)

    :sys.replace_state(pid, fn state ->
      Map.put(state, :points, [%{metric_key: "bad.metric", value: 1.0, inserted_at: "bad"}])
    end)

    assert :ok = GenServer.stop(pid, :shutdown)
    refute Process.alive?(pid)
    refute Repo.exists?(from p in Point, where: p.metric_key == "bad.metric")
  end

  defp reload_collector_policy do
    if Process.whereis(Collector) do
      Collector.reload_policy()
      _ = :sys.get_state(Collector)
    end

    :ok
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      receive do
      after
        20 -> assert_eventually(fun, attempts - 1)
      end
    end
  end
end
