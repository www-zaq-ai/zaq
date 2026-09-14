defmodule Zaq.Ingestion.ExtensionPrerequisitesTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Ingestion.{Chunk, FTSBackend}
  alias Zaq.Repo.ExtensionChecks

  setup do
    on_exit(fn -> FTSBackend.reset_cache() end)
    :ok
  end

  property "vector verification is repeatable and preserves extension ownership" do
    original =
      Repo.query!("SELECT extowner, extversion FROM pg_extension WHERE extname = 'vector'")

    check all(repetitions <- integer(1..5), max_runs: 5) do
      for _ <- 1..repetitions do
        assert :ok = ExtensionChecks.require!(Repo, :vector)
      end

      assert Repo.query!("SELECT extowner, extversion FROM pg_extension WHERE extname = 'vector'").rows ==
               original.rows
    end
  end

  test "an invisible halfvec type gives both operator script choices before creating chunks" do
    Repo.query!("SET LOCAL search_path TO pg_catalog")

    error = assert_raise Postgrex.Error, fn -> ExtensionChecks.require!(Repo, :vector) end

    assert error.postgres.message =~ "vector >= 0.7.0"
    assert error.postgres.hint =~ "scripts/setup_postgres_extensions.sql"
    assert error.postgres.hint =~ "scripts/setup_paradedb_extensions.sql"
    assert error.postgres.hint =~ "same database"
  end

  test "chunk creation and reset preserve the DBA-managed vector extension" do
    original = Repo.query!("SELECT oid, extowner FROM pg_extension WHERE extname = 'vector'")
    assert :ok = Chunk.reset_table(384)
    assert :ok = Chunk.create_table(384)

    assert Repo.query!("SELECT oid, extowner FROM pg_extension WHERE extname = 'vector'").rows ==
             original.rows

    assert %{rows: [["halfvec(384)"]]} =
             Repo.query!("""
             SELECT format_type(atttypid, atttypmod) FROM pg_attribute
             WHERE attrelid = 'chunks'::regclass AND attname = 'embedding'
             """)
  end

  test "ParadeDB prerequisite either succeeds or identifies its operator script" do
    case Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_search')") do
      %{rows: [[true]]} ->
        assert :ok = ExtensionChecks.require!(Repo, :pg_search)

      %{rows: [[false]]} ->
        error =
          assert_raise Postgrex.Error, fn -> FTSBackend.ParadeDB.setup_bm25_index(Repo, 384) end

        assert error.postgres.message =~ "pg_search"
        assert error.postgres.hint =~ "scripts/setup_paradedb_extensions.sql"
    end
  end

  @tag :paradedb
  test "ParadeDB setup preserves extension ownership" do
    original = Repo.query!("SELECT oid, extowner FROM pg_extension WHERE extname = 'pg_search'")
    assert :ok = ExtensionChecks.require!(Repo, :pg_search)
    assert :ok = Chunk.reset_table(384)
    assert :ok = FTSBackend.ParadeDB.setup_bm25_index(Repo, 384)

    assert Repo.query!("SELECT oid, extowner FROM pg_extension WHERE extname = 'pg_search'").rows ==
             original.rows
  end
end
