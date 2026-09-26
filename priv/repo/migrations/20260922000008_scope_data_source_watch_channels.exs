defmodule Zaq.Repo.Migrations.ScopeDataSourceWatchChannels do
  use Ecto.Migration

  def up do
    drop unique_index(:data_source_watch_channels, [:provider, :channel_id])

    create unique_index(:data_source_watch_channels, [:config_id, :provider, :channel_id],
             name: :data_source_watch_channels_connector_channel_index
           )
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM data_source_watch_channels
        GROUP BY provider, channel_id HAVING COUNT(*) > 1
      ) THEN
        RAISE EXCEPTION 'Cannot remove connector scope with colliding provider watch IDs';
      END IF;
    END $$
    """

    drop index(:data_source_watch_channels, [:config_id, :provider, :channel_id],
           name: :data_source_watch_channels_connector_channel_index
         )

    create unique_index(:data_source_watch_channels, [:provider, :channel_id])
  end
end
