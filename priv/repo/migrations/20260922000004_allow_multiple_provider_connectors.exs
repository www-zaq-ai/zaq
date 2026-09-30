defmodule Zaq.Repo.Migrations.AllowMultipleProviderConnectors do
  use Ecto.Migration

  def up do
    drop unique_index(:channel_configs, [:provider])
    create index(:channel_configs, [:provider])
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM channel_configs GROUP BY provider HAVING COUNT(*) > 1
      ) THEN
        RAISE EXCEPTION 'Cannot restore unique provider index with multiple connectors';
      END IF;
    END $$
    """

    drop index(:channel_configs, [:provider])
    create unique_index(:channel_configs, [:provider])
  end
end
