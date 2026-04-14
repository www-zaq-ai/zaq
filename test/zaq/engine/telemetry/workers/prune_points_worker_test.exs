defmodule Zaq.Engine.Telemetry.Workers.PrunePointsWorkerTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Engine.Telemetry.Workers.PrunePointsWorker
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.System.Config

  setup do
    Repo.delete_all(Point)
    Repo.delete_all(from c in Config, where: c.key == "telemetry.raw_retention_days")

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

  test "perform/1 uses default 60-day retention when config is missing" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old = DateTime.add(now, -70, :day)
    fresh = DateTime.add(now, -30, :day)

    insert_point(old)
    insert_point(fresh)

    Repo.delete_all(from c in Config, where: c.key == "telemetry.raw_retention_days")
    assert is_nil(System.get_config("telemetry.raw_retention_days"))

    assert :ok = PrunePointsWorker.perform(%{})

    refute Repo.exists?(from p in Point, where: p.occurred_at == ^old)
    assert Repo.exists?(from p in Point, where: p.occurred_at == ^fresh)
  end

  test "perform/1 parses integer prefixes from string configs" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old = DateTime.add(now, -40, :day)
    fresh = DateTime.add(now, -10, :day)

    insert_point(old)
    insert_point(fresh)

    assert {:ok, _} = System.set_config("telemetry.raw_retention_days", "30days")
    assert :ok = PrunePointsWorker.perform(%{})

    refute Repo.exists?(from p in Point, where: p.occurred_at == ^old)
    assert Repo.exists?(from p in Point, where: p.occurred_at == ^fresh)
  end

  test "perform/1 accepts zero-day retention from string config" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    old = DateTime.add(now, -1, :day)
    future = DateTime.add(now, 1, :day)

    insert_point(old)
    insert_point(future)

    assert {:ok, _} = System.set_config("telemetry.raw_retention_days", "0")
    assert :ok = PrunePointsWorker.perform(%{})

    refute Repo.exists?(from p in Point, where: p.occurred_at == ^old)
    assert Repo.exists?(from p in Point, where: p.occurred_at == ^future)
  end

  defp insert_point(occurred_at) do
    Repo.insert!(%Point{
      metric_key: "qa.message.count",
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
