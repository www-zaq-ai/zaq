defmodule Zaq.Repo.Migrations.AddDiskDataSourceChannelConfig do
  use Ecto.Migration

  # The disk data source fronts ingestion volumes ZAQ already owns, so unlike a connected
  # provider it has nothing for an operator to enter — no URL, no token, no OAuth grant. It
  # still needs a `channel_configs` row, because that row is how `Bridge.fetch_channel_config/1`
  # finds the provider at dispatch time. `url` and `token` are empty strings rather than NULL
  # to match what the `data_source` branch of `ChannelConfig.changeset/2` writes for every
  # other datasource.
  def up do
    execute("""
    INSERT INTO channel_configs (name, provider, kind, url, token, enabled, settings, inserted_at, updated_at)
    VALUES ('Disk', 'disk', 'data_source', '', '', true, '{}'::jsonb, now(), now())
    ON CONFLICT (provider) DO NOTHING
    """)
  end

  def down do
    execute("DELETE FROM channel_configs WHERE provider = 'disk'")
  end
end
