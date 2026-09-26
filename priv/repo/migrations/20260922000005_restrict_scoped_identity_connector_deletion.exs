defmodule Zaq.Repo.Migrations.RestrictScopedIdentityConnectorDeletion do
  use Ecto.Migration

  # Test databases that applied the earlier unconsumed migration must also
  # receive the corrected FK; fresh databases get the safe FK from 00003.
  def up do
    execute "ALTER TABLE channels DROP CONSTRAINT channels_channel_config_id_fkey"

    execute """
    ALTER TABLE channels ADD CONSTRAINT channels_channel_config_id_fkey
      FOREIGN KEY (channel_config_id) REFERENCES channel_configs(id) ON DELETE NO ACTION
    """
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM channels WHERE channel_config_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Cannot weaken connector identity FK while scoped identities exist';
      END IF;
    END $$
    """

    execute "ALTER TABLE channels DROP CONSTRAINT channels_channel_config_id_fkey"

    execute """
    ALTER TABLE channels ADD CONSTRAINT channels_channel_config_id_fkey
      FOREIGN KEY (channel_config_id) REFERENCES channel_configs(id) ON DELETE SET NULL
    """
  end
end
