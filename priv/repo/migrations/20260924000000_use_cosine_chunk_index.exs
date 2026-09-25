defmodule Zaq.Repo.Migrations.UseCosineChunkIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    if chunks_exist?() do
      execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_embedding_idx"

      execute """
      CREATE INDEX CONCURRENTLY chunks_embedding_idx ON chunks
      USING hnsw (embedding halfvec_cosine_ops)
      WITH (m = 16, ef_construction = 64)
      """
    end
  end

  def down do
    if chunks_exist?() do
      execute "DROP INDEX CONCURRENTLY IF EXISTS chunks_embedding_idx"

      execute """
      CREATE INDEX CONCURRENTLY chunks_embedding_idx ON chunks
      USING hnsw (embedding halfvec_l2_ops)
      WITH (m = 16, ef_construction = 64)
      """
    end
  end

  defp chunks_exist? do
    %{rows: [[exists?]]} =
      Ecto.Adapters.SQL.query!(repo(), "SELECT to_regclass('public.chunks') IS NOT NULL", [])

    exists?
  end
end
