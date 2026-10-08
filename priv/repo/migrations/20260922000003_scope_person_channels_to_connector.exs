defmodule Zaq.Repo.Migrations.ScopePersonChannelsToConnector do
  use Ecto.Migration

  def up do
    alter table(:channels) do
      add :channel_config_id, references(:channel_configs, on_delete: :nothing)
    end

    # A legacy provider identity can only be linked when there is exactly one
    # retrieval connector for that provider. Do not guess from display or email.
    execute """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM channels c
        JOIN channel_configs cc ON
          cc.kind = 'retrieval' AND
          (cc.provider = c.platform OR (c.platform = 'email' AND cc.provider = 'email:imap'))
        GROUP BY c.id HAVING COUNT(DISTINCT cc.id) > 1
      ) THEN
        RAISE EXCEPTION 'Ambiguous connector for legacy PersonChannel identity';
      END IF;
    END $$
    """

    execute """
    UPDATE channels c SET channel_config_id = cc.id
    FROM channel_configs cc
    WHERE cc.kind = 'retrieval' AND
      (cc.provider = c.platform OR (c.platform = 'email' AND cc.provider = 'email:imap'))
    """

    drop index(:channels, [:platform, :channel_identifier])

    create unique_index(:channels, [:platform, :channel_config_id, :channel_identifier],
             name: :channels_connector_identifier_index,
             where: "channel_config_id IS NOT NULL"
           )

    create unique_index(:channels, [:platform, :channel_identifier],
             name: :channels_platform_channel_identifier_index,
             where: "channel_config_id IS NULL"
           )
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM channels
        GROUP BY platform, channel_identifier HAVING COUNT(*) > 1
      ) THEN
        RAISE EXCEPTION 'Cannot remove connector scope with colliding PersonChannel identities';
      END IF;
    END $$
    """

    drop index(:channels, [:platform, :channel_identifier],
           name: :channels_platform_channel_identifier_index
         )

    drop index(:channels, [:platform, :channel_config_id, :channel_identifier],
           name: :channels_connector_identifier_index
         )

    create unique_index(:channels, [:platform, :channel_identifier])

    alter table(:channels) do
      remove :channel_config_id
    end
  end
end
