defmodule Zaq.Repo.Migrations.MigrateLegacyIncomingMessageRoutingRules do
  use Ecto.Migration

  def up do
    migrate_global_default_agent()
    migrate_provider_routes()
    migrate_email_mailbox_routes()
    migrate_retrieval_channel_routes()
    clear_legacy_routing_storage()
  end

  def down do
    :ok
  end

  defp migrate_global_default_agent do
    execute("""
    INSERT INTO incoming_message_routing_rules
      (routing_mode, configured_agent_id, inserted_at, updated_at)
    SELECT
      'agent',
      value::bigint,
      now(),
      now()
    FROM system_configs
    JOIN configured_agents agent ON agent.id = value::bigint
    WHERE key = 'channels.global_default_agent_id'
      AND value ~ '^[0-9]+$'
      AND agent.active = true
      AND agent.conversation_enabled = true
    ON CONFLICT DO NOTHING
    """)
  end

  defp migrate_provider_routes do
    execute("""
    INSERT INTO incoming_message_routing_rules
      (channel_config_id, routing_mode, configured_agent_id, inserted_at, updated_at)
    SELECT
      config.id,
      route.routing_mode,
      route.configured_agent_id,
      now(),
      now()
    FROM channel_configs config
    CROSS JOIN LATERAL (
      SELECT
        CASE
          WHEN config.settings #>> '{routing,default_agent_mode}' = 'none'
            OR config.settings #>> '{routing,default_agent_id}' IN ('__none__', 'none')
          THEN 'none'
          ELSE 'agent'
        END AS routing_mode,
        CASE
          WHEN config.settings #>> '{routing,default_agent_mode}' = 'none'
            OR config.settings #>> '{routing,default_agent_id}' IN ('__none__', 'none')
          THEN NULL
          ELSE (config.settings #>> '{routing,default_agent_id}')::bigint
        END AS configured_agent_id
      WHERE config.settings #> '{routing}' IS NOT NULL
        AND (
          config.settings #>> '{routing,default_agent_mode}' = 'none'
          OR config.settings #>> '{routing,default_agent_id}' IN ('__none__', 'none')
          OR config.settings #>> '{routing,default_agent_id}' ~ '^[0-9]+$'
        )
    ) route
    LEFT JOIN configured_agents agent ON agent.id = route.configured_agent_id
    WHERE route.routing_mode = 'none'
       OR (agent.active = true AND agent.conversation_enabled = true)
    ON CONFLICT DO NOTHING
    """)
  end

  defp migrate_email_mailbox_routes do
    execute("""
    INSERT INTO incoming_message_routing_rules
      (channel_config_id, topic_id, routing_mode, configured_agent_id, inserted_at, updated_at)
    SELECT
      config.id,
      mailbox.topic_id,
      mailbox.routing_mode,
      mailbox.configured_agent_id,
      now(),
      now()
    FROM channel_configs config
    CROSS JOIN LATERAL (
      SELECT
        NULLIF(BTRIM(entry.key), '') AS topic_id,
        CASE
          WHEN entry.value IN ('__none__', 'none') THEN 'none'
          ELSE 'agent'
        END AS routing_mode,
        CASE
          WHEN entry.value IN ('__none__', 'none') THEN NULL
          ELSE entry.value::bigint
        END AS configured_agent_id
      FROM jsonb_each_text(COALESCE(config.settings #> '{imap,agent_routing,mailboxes}', '{}'::jsonb)) AS entry(key, value)
      WHERE entry.value IN ('__none__', 'none') OR entry.value ~ '^[0-9]+$'
    ) mailbox
    LEFT JOIN configured_agents agent ON agent.id = mailbox.configured_agent_id
    WHERE mailbox.topic_id IS NOT NULL
      AND (mailbox.routing_mode = 'none' OR (agent.active = true AND agent.conversation_enabled = true))
    ON CONFLICT DO NOTHING
    """)
  end

  defp migrate_retrieval_channel_routes do
    execute("""
    INSERT INTO incoming_message_routing_rules
      (channel_config_id, retrieval_channel_id, routing_mode, configured_agent_id, inserted_at, updated_at)
    SELECT
      channel.channel_config_id,
      channel.id,
      CASE WHEN channel.agent_routing_mode = 'none' THEN 'none' ELSE 'agent' END,
      CASE WHEN channel.agent_routing_mode = 'none' THEN NULL ELSE channel.configured_agent_id END,
      now(),
      now()
    FROM retrieval_channels channel
    LEFT JOIN configured_agents agent ON agent.id = channel.configured_agent_id
    WHERE channel.agent_routing_mode = 'none'
       OR (
         channel.configured_agent_id IS NOT NULL
         AND agent.active = true
         AND agent.conversation_enabled = true
       )
    ON CONFLICT DO NOTHING
    """)
  end

  defp clear_legacy_routing_storage do
    execute("DELETE FROM system_configs WHERE key = 'channels.global_default_agent_id'")

    execute("""
    UPDATE channel_configs
    SET settings = settings #- '{routing}'
    WHERE settings #> '{routing}' IS NOT NULL
    """)

    execute("""
    UPDATE channel_configs
    SET settings = jsonb_set(settings, '{imap}', (settings->'imap') - 'agent_routing', true)
    WHERE settings #> '{imap,agent_routing}' IS NOT NULL
    """)

    execute("""
    UPDATE retrieval_channels
    SET configured_agent_id = NULL,
        agent_routing_mode = NULL
    WHERE configured_agent_id IS NOT NULL
       OR agent_routing_mode IS NOT NULL
    """)
  end
end
