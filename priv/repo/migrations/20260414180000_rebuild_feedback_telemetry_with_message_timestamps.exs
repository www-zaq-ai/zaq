defmodule Zaq.Repo.Migrations.RebuildFeedbackTelemetryWithMessageTimestamps do
  use Ecto.Migration

  @feedback_metric_keys [
    "feedback.negative.count",
    "feedback.negative.reason.count"
  ]

  @canonical_reasons [
    "Not factually correct",
    "Too slow",
    "Outdated information",
    "Did not follow my request",
    "Missing information in knowledge base"
  ]

  def up do
    metric_keys_sql = enum_sql(@feedback_metric_keys)
    reasons_sql = enum_sql(@canonical_reasons)

    execute(
      "DELETE FROM telemetry_rollups WHERE source = 'local' AND metric_key IN (#{metric_keys_sql})"
    )

    execute(
      "DELETE FROM telemetry_points WHERE source = 'local' AND metric_key IN (#{metric_keys_sql})"
    )

    execute("""
    INSERT INTO telemetry_points (metric_key, occurred_at, value, dimensions, dimension_key, source, node, inserted_at)
    SELECT
      'feedback.negative.count' AS metric_key,
      m.inserted_at AS occurred_at,
      1.0 AS value,
      jsonb_build_object(
        'channel_user_id', COALESCE(mr.channel_user_id, 'bo_user'),
        'user_id', COALESCE(mr.user_id::text, 'anonymous')
      ) AS dimensions,
      'channel_user_id=' || COALESCE(mr.channel_user_id, 'bo_user') ||
        '|user_id=' || COALESCE(mr.user_id::text, 'anonymous') AS dimension_key,
      'local' AS source,
      NULL::text AS node,
      NOW() AS inserted_at
    FROM message_ratings mr
    INNER JOIN messages m ON m.id = mr.message_id
    WHERE mr.rating <= 2
      AND m.role = 'assistant'
      AND m.inserted_at IS NOT NULL
    """)

    execute("""
    INSERT INTO telemetry_points (metric_key, occurred_at, value, dimensions, dimension_key, source, node, inserted_at)
    SELECT
      'feedback.negative.reason.count' AS metric_key,
      m.inserted_at AS occurred_at,
      1.0 AS value,
      jsonb_build_object(
        'channel_user_id', COALESCE(mr.channel_user_id, 'bo_user'),
        'feedback_reason', reason,
        'user_id', COALESCE(mr.user_id::text, 'anonymous')
      ) AS dimensions,
      'channel_user_id=' || COALESCE(mr.channel_user_id, 'bo_user') ||
        '|feedback_reason=' || reason ||
        '|user_id=' || COALESCE(mr.user_id::text, 'anonymous') AS dimension_key,
      'local' AS source,
      NULL::text AS node,
      NOW() AS inserted_at
    FROM message_ratings mr
    INNER JOIN messages m ON m.id = mr.message_id
    CROSS JOIN LATERAL UNNEST(ARRAY[#{reasons_sql}]) AS reason
    WHERE mr.rating <= 2
      AND m.role = 'assistant'
      AND m.inserted_at IS NOT NULL
      AND POSITION(LOWER(reason) IN LOWER(COALESCE(mr.comment, ''))) > 0
    """)

    execute("""
    INSERT INTO telemetry_rollups (
      metric_key,
      bucket_start,
      bucket_size,
      source,
      dimensions,
      dimension_key,
      value_sum,
      value_count,
      value_min,
      value_max,
      last_value,
      last_at,
      inserted_at,
      updated_at
    )
    SELECT
      metric_key,
      to_timestamp(FLOOR(EXTRACT(EPOCH FROM occurred_at) / 600) * 600)::timestamp AS bucket_start,
      '10m' AS bucket_size,
      source,
      dimensions,
      dimension_key,
      SUM(value) AS value_sum,
      COUNT(*)::integer AS value_count,
      MIN(value) AS value_min,
      MAX(value) AS value_max,
      (ARRAY_AGG(value ORDER BY occurred_at DESC, id DESC))[1] AS last_value,
      MAX(occurred_at) AS last_at,
      NOW() AS inserted_at,
      NOW() AS updated_at
    FROM telemetry_points
    WHERE source = 'local'
      AND metric_key IN (#{metric_keys_sql})
    GROUP BY
      metric_key,
      to_timestamp(FLOOR(EXTRACT(EPOCH FROM occurred_at) / 600) * 600)::timestamp,
      source,
      dimensions,
      dimension_key
    """)

    execute("""
    INSERT INTO system_configs (key, value, inserted_at, updated_at)
    VALUES (
      'telemetry.rollup_point_id_cursor',
      (SELECT COALESCE(MAX(id), 0)::text FROM telemetry_points),
      NOW(),
      NOW()
    )
    ON CONFLICT (key)
    DO UPDATE SET
      value = EXCLUDED.value,
      updated_at = EXCLUDED.updated_at
    """)
  end

  def down do
    metric_keys_sql = enum_sql(@feedback_metric_keys)

    execute(
      "DELETE FROM telemetry_rollups WHERE source = 'local' AND metric_key IN (#{metric_keys_sql})"
    )

    execute(
      "DELETE FROM telemetry_points WHERE source = 'local' AND metric_key IN (#{metric_keys_sql})"
    )

    execute("DELETE FROM system_configs WHERE key = 'telemetry.rollup_point_id_cursor'")
  end

  defp enum_sql(values) do
    values
    |> Enum.map(&"'#{String.replace(&1, "'", "''")}'")
    |> Enum.join(", ")
  end
end
