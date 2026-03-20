defmodule Zaq.Engine.Telemetry.Workers.PrunePointsWorkerTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Engine.Telemetry.Workers.PrunePointsWorker
  alias Zaq.Repo
  alias Zaq.System

  setup do
    Repo.delete_all(Point)
    :ok
  end

  test "perform/1 deletes points older than configured retention" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old = DateTime.add(now, -40, :day)
    fresh = DateTime.add(now, -10, :day)

    insert_point(old)
    insert_point(fresh)

    assert {:ok, _} = System.set_config("telemetry.raw_retention_days", "30")
    assert :ok = PrunePointsWorker.perform(%{})

    refute Repo.exists?(from p in Point, where: p.occurred_at == ^old)
    assert Repo.exists?(from p in Point, where: p.occurred_at == ^fresh)
  end

  test "perform/1 falls back to default retention on malformed config" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old = DateTime.add(now, -70, :day)
    fresh = DateTime.add(now, -30, :day)

    insert_point(old)
    insert_point(fresh)

    assert {:ok, _} = System.set_config("telemetry.raw_retention_days", "nope")
    assert :ok = PrunePointsWorker.perform(%{})

    refute Repo.exists?(from p in Point, where: p.occurred_at == ^old)
    assert Repo.exists?(from p in Point, where: p.occurred_at == ^fresh)
  end

  defp insert_point(occurred_at) do
    Repo.insert!(%Point{
      metric_key: "qa.question.count",
      occurred_at: occurred_at,
      value: 1.0,
      dimensions: %{},
      dimension_key: "global",
      source: "local",
      node: "test@node",
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end
end
