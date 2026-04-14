defmodule Zaq.Engine.Telemetry.Workers.AggregateRollupsWorkerTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.{Point, Rollup}
  alias Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker
  alias Zaq.Repo
  alias Zaq.System.Config

  setup do
    Repo.delete_all(Point)
    Repo.delete_all(Rollup)
    Repo.delete_all(from c in Config, where: c.key == "telemetry.rollup_point_id_cursor")
    :ok
  end

  test "perform/1 aggregates points into 10m rollups and advances point-id cursor" do
    {t1, t2} = same_bucket_times()

    insert_point("qa.answer.latency_ms", t1, 100.0)
    insert_point("qa.answer.latency_ms", t2, 200.0)

    assert :ok = AggregateRollupsWorker.perform(%{})

    rollup = Repo.one!(from r in Rollup, where: r.metric_key == "qa.answer.latency_ms")

    assert rollup.value_sum == 300.0
    assert rollup.value_count == 2
    assert rollup.value_min == 100.0
    assert rollup.value_max == 200.0
    assert rollup.last_value == 200.0
    assert rollup.last_at == t2

    assert cursor_id = Telemetry.get_cursor_id("telemetry.rollup_point_id_cursor")
    assert is_integer(cursor_id)
    assert cursor_id > 0
  end

  test "perform/1 upserts into existing rollup bucket" do
    {t1, t2} = same_bucket_times()

    insert_point("qa.answer.latency_ms", t1, 100.0)
    assert :ok = AggregateRollupsWorker.perform(%{})

    insert_point("qa.answer.latency_ms", t2, 250.0)
    assert :ok = AggregateRollupsWorker.perform(%{})

    rollup = Repo.one!(from r in Rollup, where: r.metric_key == "qa.answer.latency_ms")

    assert rollup.value_sum == 350.0
    assert rollup.value_count == 2
    assert rollup.value_min == 100.0
    assert rollup.value_max == 250.0
    assert rollup.last_value == 250.0
    assert rollup.last_at == t2
  end

  test "perform/1 aggregates late inserted backdated points" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    recent = DateTime.add(now, -10, :minute)
    backdated = DateTime.add(now, -3, :day)

    insert_point("feedback.negative.count", recent, 1.0)
    assert :ok = AggregateRollupsWorker.perform(%{})

    insert_point("feedback.negative.count", backdated, 1.0)
    assert :ok = AggregateRollupsWorker.perform(%{})

    rollups =
      from(r in Rollup,
        where: r.metric_key == "feedback.negative.count",
        order_by: [asc: r.bucket_start]
      )
      |> Repo.all()

    assert length(rollups) == 2
    assert Enum.sum(Enum.map(rollups, & &1.value_sum)) == 2.0
  end

  defp insert_point(metric_key, occurred_at, value) do
    Repo.insert!(%Point{
      metric_key: metric_key,
      value: value,
      occurred_at: occurred_at,
      dimensions: %{},
      dimension_key: "global",
      source: "local",
      node: "test@node",
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end

  defp same_bucket_times do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    bucket_offset = rem(DateTime.to_unix(now, :second), 600)
    bucket_start = DateTime.add(now, -bucket_offset, :second)

    {
      DateTime.add(bucket_start, 60, :second),
      DateTime.add(bucket_start, 180, :second)
    }
  end
end
