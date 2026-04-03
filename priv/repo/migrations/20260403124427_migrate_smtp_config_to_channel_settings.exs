defmodule Zaq.Repo.Migrations.MigrateSmtpConfigToChannelSettings do
  use Ecto.Migration

  def up do
    alter table(:channel_configs) do
      add :settings, :map, null: false, default: %{}
    end

    execute("""
    UPDATE user_notification_channels
    SET platform = 'email:smtp'
    WHERE platform = 'email'
    """)

    execute("""
    UPDATE channel_configs
    SET
      provider = 'email:smtp',
      kind = 'retrieval',
      name = COALESCE(NULLIF(name, ''), 'Email SMTP'),
      settings = jsonb_strip_nulls(
        jsonb_build_object(
          'relay', (SELECT value FROM system_configs WHERE key = 'email.relay' LIMIT 1),
          'port', (SELECT value FROM system_configs WHERE key = 'email.port' LIMIT 1),
          'transport_mode', (SELECT value FROM system_configs WHERE key = 'email.transport_mode' LIMIT 1),
          'tls', (SELECT value FROM system_configs WHERE key = 'email.tls' LIMIT 1),
          'tls_verify', (SELECT value FROM system_configs WHERE key = 'email.tls_verify' LIMIT 1),
          'ca_cert_path', (SELECT value FROM system_configs WHERE key = 'email.ca_cert_path' LIMIT 1),
          'username', (SELECT value FROM system_configs WHERE key = 'email.username' LIMIT 1),
          'password', (SELECT value FROM system_configs WHERE key = 'email.password' LIMIT 1),
          'from_email', (SELECT value FROM system_configs WHERE key = 'email.from_email' LIMIT 1),
          'from_name', (SELECT value FROM system_configs WHERE key = 'email.from_name' LIMIT 1)
        )
      )
    WHERE provider = 'email'
    """)

    execute("""
    INSERT INTO channel_configs (name, provider, kind, url, token, enabled, settings, inserted_at, updated_at)
    SELECT
      'Email SMTP',
      'email:smtp',
      'retrieval',
      'smtp://configured-in-settings',
      '__smtp_unused__',
      COALESCE(
        (
          SELECT CASE WHEN value = 'true' THEN true ELSE false END
          FROM system_configs
          WHERE key = 'email.enabled'
          LIMIT 1
        ),
        false
      ),
      jsonb_strip_nulls(
        jsonb_build_object(
          'relay', (SELECT value FROM system_configs WHERE key = 'email.relay' LIMIT 1),
          'port', (SELECT value FROM system_configs WHERE key = 'email.port' LIMIT 1),
          'transport_mode', (SELECT value FROM system_configs WHERE key = 'email.transport_mode' LIMIT 1),
          'tls', (SELECT value FROM system_configs WHERE key = 'email.tls' LIMIT 1),
          'tls_verify', (SELECT value FROM system_configs WHERE key = 'email.tls_verify' LIMIT 1),
          'ca_cert_path', (SELECT value FROM system_configs WHERE key = 'email.ca_cert_path' LIMIT 1),
          'username', (SELECT value FROM system_configs WHERE key = 'email.username' LIMIT 1),
          'password', (SELECT value FROM system_configs WHERE key = 'email.password' LIMIT 1),
          'from_email', (SELECT value FROM system_configs WHERE key = 'email.from_email' LIMIT 1),
          'from_name', (SELECT value FROM system_configs WHERE key = 'email.from_name' LIMIT 1)
        )
      ),
      now(),
      now()
    WHERE NOT EXISTS (
      SELECT 1 FROM channel_configs WHERE provider = 'email:smtp'
    )
    """)
  end

  def down do
    execute("""
    UPDATE user_notification_channels
    SET platform = 'email'
    WHERE platform = 'email:smtp'
    """)

    execute("""
    UPDATE channel_configs
    SET provider = 'email'
    WHERE provider = 'email:smtp'
    """)

    alter table(:channel_configs) do
      remove :settings
    end
  end
end
