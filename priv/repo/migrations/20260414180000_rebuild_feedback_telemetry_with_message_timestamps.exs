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

  @migration_node "migration:20260414180000"

  def up do
    feedback_metric_keys_sql = enum_sql(@feedback_metric_keys)
    reasons_sql = enum_sql(@canonical_reasons)

    execute(
      "DELETE FROM telemetry_points WHERE source = 'local' AND metric_key IN (#{feedback_metric_keys_sql})"
    )

    execute("""
    DELETE FROM telemetry_points
    WHERE source = 'local'
      AND metric_key = 'qa.message.count'
      AND COALESCE(dimensions->>'channel_type', '') <> 'api'
    """)

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
      '#{@migration_node}' AS node,
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
      '#{@migration_node}' AS node,
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
    INSERT INTO telemetry_points (metric_key, occurred_at, value, dimensions, dimension_key, source, node, inserted_at)
    SELECT
      'qa.message.count' AS metric_key,
      m.inserted_at AS occurred_at,
      1.0 AS value,
      jsonb_build_object(
        'channel_config_id', COALESCE(c.channel_config_id::text, 'unknown'),
        'channel_type', COALESCE(c.channel_type, 'unknown'),
        'role', 'user'
      ) AS dimensions,
      'channel_config_id=' || COALESCE(c.channel_config_id::text, 'unknown') ||
        '|channel_type=' || COALESCE(c.channel_type, 'unknown') ||
        '|role=user' AS dimension_key,
      'local' AS source,
      '#{@migration_node}' AS node,
      NOW() AS inserted_at
    FROM messages m
    INNER JOIN conversations c ON c.id = m.conversation_id
    WHERE m.role = 'user'
      AND m.inserted_at IS NOT NULL
    """)

    execute("""
    WITH qa_totals AS (
      SELECT
        to_timestamp(FLOOR(EXTRACT(EPOCH FROM occurred_at) / 600) * 600)::timestamp AS bucket_start,
        COALESCE(dimensions->>'channel_type', 'unknown') AS channel_type,
        COALESCE(dimensions->>'channel_config_id', 'unknown') AS channel_config_id,
        SUM(CASE WHEN metric_key = 'qa.message.count' THEN value ELSE 0 END) AS message_total,
        SUM(CASE WHEN metric_key = 'qa.no_answer.count' THEN value ELSE 0 END) AS no_answer_total
      FROM telemetry_points
      WHERE source = 'local'
        AND metric_key IN ('qa.message.count', 'qa.no_answer.count')
      GROUP BY
        to_timestamp(FLOOR(EXTRACT(EPOCH FROM occurred_at) / 600) * 600)::timestamp,
        COALESCE(dimensions->>'channel_type', 'unknown'),
        COALESCE(dimensions->>'channel_config_id', 'unknown')
    )
    INSERT INTO telemetry_points (metric_key, occurred_at, value, dimensions, dimension_key, source, node, inserted_at)
    SELECT
      'qa.message.count' AS metric_key,
      bucket_start AS occurred_at,
      (no_answer_total - message_total) AS value,
      jsonb_build_object(
        'channel_config_id', channel_config_id,
        'channel_type', channel_type,
        'role', 'user'
      ) AS dimensions,
      'channel_config_id=' || channel_config_id || '|channel_type=' || channel_type || '|role=user' AS dimension_key,
      'local' AS source,
      '#{@migration_node}' AS node,
      NOW() AS inserted_at
    FROM qa_totals
    WHERE no_answer_total > message_total
    """)

    execute("DELETE FROM telemetry_rollups WHERE source = 'local'")

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
    raise "Irreversible migration"
  end

  defp enum_sql(values) do
    values
    |> Enum.map(&"'#{String.replace(&1, "'", "''")}'")
    |> Enum.join(", ")
  end
end
