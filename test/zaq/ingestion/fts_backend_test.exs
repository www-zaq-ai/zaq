defmodule Zaq.Ingestion.FTSBackendTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{Chunk, FTSBackend}
  alias Zaq.Repo

  setup do
    FTSBackend.reset_cache()
    on_exit(fn -> FTSBackend.reset_cache() end)
    :ok
  end

  # The sandbox rolls back DDL issued here, so dropping the index only
  # affects the current test.
  defp drop_bm25_index do
    Repo.query!("DROP INDEX IF EXISTS chunks_bm25_idx")
  end

  # chunks is created at runtime (dynamic embedding dimension), not by
  # migrations, so fresh CI databases need it before a BM25 index can exist.
  # Native is pinned during creation so Chunk.create_table/1's internal
  # backend lookup cannot cache a detection result mid-setup. All DDL rolls
  # back with the sandbox.
  defp create_chunks_table_with_bm25_index do
    :persistent_term.put({FTSBackend, :backend}, FTSBackend.Native)
    Chunk.create_table(1536)
    FTSBackend.ParadeDB.setup_bm25_index(Repo, 1536)
    FTSBackend.reset_cache()
  end

  describe "detect_and_cache/0" do
    test "selects the native backend when no usable ParadeDB setup exists" do
      # On plain Postgres paradedb.version_info() is undefined; on a ParadeDB
      # server the dropped BM25 index fails the second detection condition.
      # Either way the native backend must win.
      drop_bm25_index()

      assert FTSBackend.detect_and_cache() == FTSBackend.Native
    end

    test "does not abort an enclosing transaction when ParadeDB is absent" do
      # Regression: the version_info() probe erroring on native Postgres used
      # to poison the surrounding transaction, so any later statement failed
      # with 25P02 (e.g. Chunk.create_table/1 inside save_embedding_config's
      # Ecto.Multi). The sandbox already wraps this test in a transaction.
      drop_bm25_index()

      FTSBackend.detect_and_cache()

      assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")
    end

    test "caches the detected backend in :persistent_term" do
      drop_bm25_index()

      backend = FTSBackend.detect_and_cache()

      assert :persistent_term.get({FTSBackend, :backend}, nil) == backend
    end

    @tag :paradedb
    test "selects the ParadeDB backend when version_info() works and the BM25 index exists" do
      create_chunks_table_with_bm25_index()

      assert FTSBackend.detect_and_cache() == FTSBackend.ParadeDB
    end
  end

  describe "impl/0" do
    test "returns the cached backend without re-detecting" do
      :persistent_term.put({FTSBackend, :backend}, FTSBackend.ParadeDB)

      assert FTSBackend.impl() == FTSBackend.ParadeDB
    end

    test "detects and caches on first call when nothing is cached" do
      drop_bm25_index()

      assert FTSBackend.impl() == FTSBackend.Native
      assert :persistent_term.get({FTSBackend, :backend}, nil) == FTSBackend.Native
    end

    @tag :paradedb
    test "returns the ParadeDB backend on a working ParadeDB installation" do
      create_chunks_table_with_bm25_index()

      assert FTSBackend.impl() == FTSBackend.ParadeDB
    end
  end

  describe "reset_cache/0" do
    test "clears the cached backend so the next impl/0 call re-detects" do
      :persistent_term.put({FTSBackend, :backend}, FTSBackend.ParadeDB)
      FTSBackend.reset_cache()
      drop_bm25_index()

      assert FTSBackend.impl() == FTSBackend.Native
    end
  end
end
