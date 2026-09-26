defmodule Zaq.E2E.TelemetryFixturesTest do
  use Zaq.DataCase, async: false

  import ExUnit.CaptureLog

  alias Zaq.E2E.TelemetryFixtures
  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.{Buffer, Point, Rollup}
  alias Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker, as: Aggregate

  @oban __MODULE__.Oban

  test "clear removes persisted and buffered LLM metrics, retaining unrelated telemetry" do
    record("qa.llm.call.count")
    :ok = Buffer.flush()
    :ok = Aggregate.perform(%Oban.Job{})
    record("qa.tokens.total")
    Telemetry.record("qa.message.count", 1, %{})

    conn =
      ZaqWeb.E2EController.seed_llm_performance(Phoenix.ConnTest.build_conn(), %{
        "mode" => "clear"
      })

    assert conn.status == 200
    assert Repo.aggregate(llm_points(), :count) == 0
    :ok = Buffer.flush()
    :ok = Aggregate.perform(%Oban.Job{})
    refute Repo.exists?(llm_rollups())
    assert Repo.exists?(from row in Rollup, where: row.metric_key == "qa.message.count")
  end

  test "seed replaces old telemetry and remains unchanged after aggregation" do
    record("qa.llm.call.count")
    conn = ZaqWeb.E2EController.seed_llm_performance(Phoenix.ConnTest.build_conn(), %{})
    assert conn.status == 200
    before = Repo.all(llm_rollups() |> order_by(:id))
    assert length(before) == 25
    refute Enum.any?(before, &(&1.dimensions["model"] == "e2e-fake"))
    :ok = Buffer.flush()
    :ok = Aggregate.perform(%Oban.Job{})
    assert Repo.all(llm_rollups() |> order_by(:id)) == before
  end

  test "waits for a running aggregation before clearing and restores dispatch" do
    start_queue()
    record("qa.llm.call.count")
    :ok = Buffer.flush()
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:zaq, :repo, :query],
        fn _, _, meta, _ ->
          if self() != parent and String.starts_with?(meta.query, "SELECT") and
               String.contains?(meta.query, "FROM \"telemetry_points\"") do
            send(parent, {:points_read, self()})

            receive do
              :release -> :ok
            after
              5_000 -> raise "aggregation was not released"
            end
          end
        end,
        nil
      )

    task =
      Task.async(fn ->
        receive do
          :reset ->
            TelemetryFixtures.reset_llm_performance!(fn -> send(parent, :seeding) end,
              oban: @oban
            )
        end
      end)

    # Observe the real suspension acknowledgement, without timing-based sleeps.
    :erlang.trace_pattern({:sys, :suspend, 2}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(task.pid, true, [:call])

    try do
      Oban.insert!(@oban, Aggregate.new(%{}))
      # PostgreSQL notifications are deferred until the Sandbox transaction commits.
      send(Oban.Registry.whereis(@oban, {:producer, "telemetry"}), :dispatch)
      assert_receive {:points_read, worker}, 2_000
      send(task.pid, :reset)
      reset_pid = task.pid
      assert_receive {:trace, ^reset_pid, :return_from, {:sys, :suspend, 2}, :ok}, 2_000
      refute_received :seeding
      assert Repo.exists?(llm_points())
      send(worker, :release)
      assert Task.await(task) == :seeding
      assert_received :seeding
      refute Repo.exists?(llm_rollups())
      refute Repo.exists?(llm_points())
      assert %{paused: false} = Oban.check_queue(@oban, queue: :telemetry)
      :ok = Aggregate.perform(%Oban.Job{})
      refute Repo.exists?(llm_rollups())
    after
      :telemetry.detach(handler)
      :erlang.trace_pattern({:sys, :suspend, 2}, false, [:local])
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      :sys.resume(Oban.Registry.whereis(@oban, {:producer, "telemetry"}))
    end
  end

  test "a failed seed rolls back deletion and preserves an already paused queue" do
    start_queue(paused: true)
    record("qa.llm.call.count")
    :ok = Buffer.flush()
    :ok = Aggregate.perform(%Oban.Job{})

    assert_raise RuntimeError, "seed failed", fn ->
      TelemetryFixtures.reset_llm_performance!(fn -> raise "seed failed" end, oban: @oban)
    end

    assert Repo.exists?(llm_points())
    assert Repo.exists?(llm_rollups())
    assert %{paused: true} = Oban.check_queue(@oban, queue: :telemetry)
  end

  test "a retained buffer point fails reset instead of reporting successful clearing" do
    start_queue()
    buffer = start_supervised!({Buffer, name: nil, flush_interval_ms: 60_000})
    # NULL violates the database metric_key constraint; Buffer catches the error.
    Buffer.enqueue(buffer, %{metric_key: nil, value: 1})

    assert capture_log(fn ->
             assert_raise RuntimeError, ~r/telemetry flush retained 1 points/, fn ->
               TelemetryFixtures.reset_llm_performance!(fn -> flunk("must not seed") end,
                 oban: @oban,
                 buffer: buffer
               )
             end
           end) =~ "Failed to flush"

    assert %{paused: false} = Oban.check_queue(@oban, queue: :telemetry)
    # Prevent this deliberately invalid point from being flushed at shutdown.
    :sys.replace_state(buffer, &%{&1 | points: []})
  end

  defp start_queue(opts \\ []) do
    config = Application.fetch_env!(:zaq, Oban)

    config =
      Keyword.merge(config,
        name: @oban,
        plugins: [],
        queues: [telemetry: Keyword.merge([limit: 1], opts)],
        testing: :disabled,
        peer: {Oban.Peers.Isolated, [leader?: true]}
      )

    start_supervised!({Oban, config})
  end

  defp record(metric) do
    Telemetry.record(metric, 1, %{"model" => "e2e-fake", "llm_usage_attribution" => "v1"})
  end

  defp llm_points do
    from row in Point,
      where: like(row.metric_key, "qa.llm.%") or like(row.metric_key, "qa.tokens.%")
  end

  defp llm_rollups do
    from row in Rollup,
      where: like(row.metric_key, "qa.llm.%") or like(row.metric_key, "qa.tokens.%")
  end
end
