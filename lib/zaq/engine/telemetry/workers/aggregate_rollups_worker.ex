defmodule Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker do
  @moduledoc """
  Aggregates raw telemetry points into rollup buckets.

  The worker uses a cursor (`telemetry.rollup_cursor`) to process points once.
  """

  use Oban.Worker, queue: :telemetry, max_attempts: 5

  import Ecto.Query

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.{Point, Rollup}
  alias Zaq.Repo

  @cursor_key "telemetry.rollup_cursor"
  @batch_size 5_000
  @bucket_seconds 600

  @impl Oban.Worker
  def perform(_job) do
    cursor = Telemetry.get_cursor(@cursor_key) || DateTime.add(DateTime.utc_now(), -90, :day)

    points =
      from(p in Point,
        where: p.occurred_at > ^cursor,
        order_by: [asc: p.occurred_at],
        limit: @batch_size
      )
      |> Repo.all()

    case points do
      [] ->
        :ok

      _ ->
        points
        |> build_rollup_rows()
        |> upsert_rollups()

        points
        |> List.last()
        |> then(&Telemetry.put_cursor(@cursor_key, &1.occurred_at))

        :ok
    end
  end

  defp build_rollup_rows(points) do
    now = DateTime.utc_now()

    points
    |> Enum.group_by(&row_key/1)
    |> Enum.map(fn {{metric_key, bucket_start, source, dimensions, dimension_key}, grouped_points} ->
      values = Enum.map(grouped_points, & &1.value)
      last = List.last(grouped_points)

      %{
        metric_key: metric_key,
        bucket_start: bucket_start,
        bucket_size: "10m",
        source: source,
        dimensions: dimensions,
        dimension_key: dimension_key,
        value_sum: Enum.sum(values),
        value_count: length(values),
        value_min: Enum.min(values),
        value_max: Enum.max(values),
        last_value: last.value,
        last_at: last.occurred_at,
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp row_key(point) do
    {
      point.metric_key,
      floor_to_bucket(point.occurred_at),
      point.source,
      point.dimensions,
      point.dimension_key
    }
  end

  defp floor_to_bucket(%DateTime{} = datetime) do
    bucket_seconds =
      datetime
      |> DateTime.to_unix(:second)
      |> then(&(&1 - rem(&1, @bucket_seconds)))

    DateTime.from_unix!(bucket_seconds * 1_000_000, :microsecond)
  end

  defp upsert_rollups([]), do: :ok

  defp upsert_rollups(rows) do
    conflict_query =
      from(r in Rollup,
        update: [
          set: [
            value_sum: fragment("? + EXCLUDED.value_sum", r.value_sum),
            value_count: fragment("? + EXCLUDED.value_count", r.value_count),
            value_min: fragment("LEAST(?, EXCLUDED.value_min)", r.value_min),
            value_max: fragment("GREATEST(?, EXCLUDED.value_max)", r.value_max),
            last_value:
              fragment(
                "CASE WHEN EXCLUDED.last_at >= ? THEN EXCLUDED.last_value ELSE ? END",
                r.last_at,
                r.last_value
              ),
            last_at: fragment("GREATEST(?, EXCLUDED.last_at)", r.last_at),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )

    Repo.insert_all(Rollup, rows,
      conflict_target: [:metric_key, :bucket_start, :bucket_size, :source, :dimension_key],
      on_conflict: conflict_query
    )

    :ok
  end
end
