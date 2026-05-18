defmodule Zaq.Repo.Migrations.RenameIngestionChannelKindToDataSource do
  use Ecto.Migration

  def up do
    execute("UPDATE channel_configs SET kind = 'data_source' WHERE kind = 'ingestion'")
  end

  def down do
    execute("UPDATE channel_configs SET kind = 'ingestion' WHERE kind = 'data_source'")
  end
end
