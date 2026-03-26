defmodule Zaq.Repo.Migrations.ResetIngestion do
  use Ecto.Migration

  alias Zaq.Ingestion.Chunk

  def up do
    Chunk.drop_table()
  end

  def down do
    :ok
  end
end
