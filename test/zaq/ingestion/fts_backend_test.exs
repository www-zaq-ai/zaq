defmodule Zaq.Ingestion.FTSBackendTest do
  use Zaq.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Zaq.Ingestion.{Chunk, FTSBackend}
  alias Zaq.Repo

  setup do
    FTSBackend.reset_cache()
    on_exit(fn -> FTSBackend.reset_cache() end)
    :ok
  end

  # Pins the one state that must select Native on any server: a chunks
  # table without the BM25 index. On plain Postgres the extension probe
  # fails anyway; on a ParadeDB server the indexless table is what forces
  # Native — a missing table would select ParadeDB (fresh install). The
  # sandbox rolls back the DDL.
  defp force_indexless_chunks_table do
    Repo.query!("CREATE TABLE IF NOT EXISTS chunks (id bigserial PRIMARY KEY)")
    Repo.query!("DROP INDEX IF EXISTS chunks_bm25_idx")
  end

  # chunks is created at runtime (dynamic embedding dimension), not by
  # migrations, so fresh CI databases need it before a BM25 index can exist.
  # On a ParadeDB server create_table provisions chunks_bm25_idx itself —
  # no manual index creation, so these tests exercise the real bootstrap
  # path. All DDL rolls back with the sandbox.
  defp create_chunks_table_with_bm25_index do
    Chunk.create_table(1536)
    FTSBackend.reset_cache()
  end

  defp ensure_callable_paradedb_version_info do
    case Repo.query("""
         SELECT 1 FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'paradedb' AND p.proname = 'version_info'
         LIMIT 1
         """) do
      {:ok, %{rows: [_ | _]}} ->
        :ok

      _ ->
        create_fake_paradedb_version_info()
    end
  end

  defp create_fake_paradedb_version_info do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS paradedb")

    Repo.query!("""
    CREATE OR REPLACE FUNCTION paradedb.version_info()
    RETURNS integer
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RETURN 1;
    END;
    $$;
    """)
  end

  describe "detect_and_cache/0" do
    test "selects the native backend when no usable ParadeDB setup exists" do
      # On plain Postgres paradedb.version_info() is undefined; on a ParadeDB
      # server the existing-but-indexless chunks table fails the index
      # condition. Either way the native backend must win.
      force_indexless_chunks_table()

      assert FTSBackend.detect_and_cache() == FTSBackend.Native
    end

    test "does not abort an enclosing transaction when ParadeDB is absent" do
      # Regression: the version_info() probe erroring on native Postgres used
      # to poison the surrounding transaction, so any later statement failed
      # with 25P02 (e.g. Chunk.create_table/1 inside save_embedding_config's
      # Ecto.Multi). The sandbox already wraps this test in a transaction.
      force_indexless_chunks_table()

      FTSBackend.detect_and_cache()

      assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT 1")
    end

    test "caches the detected backend in :persistent_term" do
      force_indexless_chunks_table()

      backend = FTSBackend.detect_and_cache()

      assert :persistent_term.get({FTSBackend, :backend}, nil) == backend
    end

    test "selects ParadeDB when the function is callable and BM25 index is present" do
      # The fake version_info must be created after the table: create_table
      # dispatches index setup on the functional probe, and a fake probe on
      # plain Postgres would send it down the pg_search path.
      Chunk.create_table(1536)
      ensure_callable_paradedb_version_info()
      Repo.query!("CREATE INDEX IF NOT EXISTS chunks_bm25_idx ON chunks(id)")
      FTSBackend.reset_cache()

      assert FTSBackend.detect_and_cache() == FTSBackend.ParadeDB
    end

    test "selects ParadeDB on a fresh install when the probe works before chunks exists" do
      Repo.query!("DROP TABLE IF EXISTS chunks")
      Repo.query!("DROP INDEX IF EXISTS chunks_bm25_idx")
      ensure_callable_paradedb_version_info()
      FTSBackend.reset_cache()

      assert FTSBackend.detect_and_cache() == FTSBackend.ParadeDB
    end

    @tag :paradedb
    test "selects the ParadeDB backend when version_info() works and the BM25 index exists" do
      create_chunks_table_with_bm25_index()

      assert FTSBackend.detect_and_cache() == FTSBackend.ParadeDB
    end
  end

  describe "fresh install bootstrap" do
    # Reproduces the real bootstrap sequence on a ParadeDB server instead of
    # hand-creating chunks_bm25_idx: boot-time detection runs before the
    # chunks table exists, then an admin configures embeddings
    # (Chunk.create_table/1). ParadeDB must become active without manual
    # index creation — migrations cannot create chunks_bm25_idx because
    # chunks itself is only created at runtime.
    @tag :paradedb
    test "activates ParadeDB after the chunks table is created on a fresh install" do
      Repo.query!("DROP TABLE IF EXISTS chunks")
      FTSBackend.reset_cache()

      # Boot-time detection on a fresh database: no chunks table exists yet,
      # so nothing can be searched — a functional extension alone must
      # already select ParadeDB.
      assert FTSBackend.detect_and_cache() == FTSBackend.ParadeDB

      Chunk.create_table(1536)

      assert {:ok, %{rows: [[1]]}} =
               Repo.query("SELECT 1 FROM pg_indexes WHERE indexname = 'chunks_bm25_idx'"),
             "chunks_bm25_idx was not created during chunks table setup"

      assert FTSBackend.impl() == FTSBackend.ParadeDB
    end

    # A model/dimension change drops and recreates the chunks table
    # (Chunk.reset_table/1 via System.save_embedding_config). DROP TABLE
    # takes chunks_bm25_idx with it, so recreation must provision the index
    # again and keep the ParadeDB backend active.
    @tag :paradedb
    test "keeps ParadeDB active when a dimension change recreates the chunks table" do
      create_chunks_table_with_bm25_index()
      assert FTSBackend.impl() == FTSBackend.ParadeDB

      Chunk.reset_table(384)

      assert {:ok, %{rows: [[1]]}} =
               Repo.query("SELECT 1 FROM pg_indexes WHERE indexname = 'chunks_bm25_idx'")

      assert FTSBackend.impl() == FTSBackend.ParadeDB
    end
  end

  describe "impl/0" do
    test "returns the cached backend without re-detecting" do
      :persistent_term.put({FTSBackend, :backend}, FTSBackend.ParadeDB)

      assert FTSBackend.impl() == FTSBackend.ParadeDB
    end

    test "detects and caches on first call when nothing is cached" do
      force_indexless_chunks_table()

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
      force_indexless_chunks_table()

      assert FTSBackend.impl() == FTSBackend.Native
    end
  end

  describe "query helpers" do
    test "rows_present? returns true only when a SQL result has rows" do
      assert FTSBackend.rows_present?({:ok, %{rows: [[1]]}})
      refute FTSBackend.rows_present?({:ok, %{rows: []}})
      refute FTSBackend.rows_present?({:error, :unavailable})
    end

    test "callable_probe_result returns false for SQL errors" do
      assert FTSBackend.callable_probe_result({:ok, %{rows: [[1]]}})

      Logger.put_module_level(FTSBackend, :debug)
      on_exit(fn -> Logger.delete_module_level(FTSBackend) end)

      log =
        capture_log([level: :debug], fn ->
          refute FTSBackend.callable_probe_result({:error, :missing_function})
        end)

      assert log =~ "paradedb.version_info() not callable"
    end

    test "sanitize_query_text removes invalid bytes, punctuation, and excessive length" do
      raw = "  what\xFF's: up?\0 " <> String.duplicate("x", 600)

      sanitized = FTSBackend.sanitize_query_text(raw)

      assert String.starts_with?(sanitized, "what s up")
      assert byte_size(sanitized) <= 512
      refute String.contains?(sanitized, <<0>>)
      refute String.contains?(sanitized, <<0xFF>>)
    end

    test "sanitize_query_text strips invalid leading bytes before sanitizing" do
      raw = <<0xC3, 0x28>>

      assert FTSBackend.sanitize_query_text(raw) == ""
    end

    test "maybe_filter_source leaves an unfiltered query unchanged" do
      query = from(c in Chunk, select: c.id)

      assert FTSBackend.maybe_filter_source(query, []) == query
    end

    test "maybe_filter_source joins documents and applies source filter" do
      query =
        Chunk
        |> select([c], c.id)
        |> FTSBackend.maybe_filter_source(["docs/handbook"])

      {sql, params} = SQL.to_sql(:all, Repo, query)

      assert sql =~ ~s(INNER JOIN "documents")
      assert sql =~ "document_id"
      assert params == ["docs/handbook/%"]
    end

    test "group_results nests rows by document and section path" do
      results = [
        %{document_id: 1, section_path: ["A"], bm25_score: 2.0},
        %{document_id: 1, section_path: ["A"], bm25_score: 1.0},
        %{document_id: 2, section_path: ["B"], bm25_score: 3.0}
      ]

      assert %{
               1 => %{["A"] => [%{bm25_score: 2.0}, %{bm25_score: 1.0}]},
               2 => %{["B"] => [%{bm25_score: 3.0}]}
             } = FTSBackend.group_results(results)
    end
  end

  describe "ParadeDB query construction" do
    test "sanitize_query delegates to shared query sanitization" do
      assert FTSBackend.ParadeDB.sanitize_query("alpha:beta OR gamma") == "alpha beta OR gamma"
    end

    test "bm25_query sanitizes input and uses ParadeDB AND semantics" do
      query = FTSBackend.ParadeDB.bm25_query("alpha:(beta)^2", 11)

      {sql, params} = SQL.to_sql(:all, Repo, query)

      assert sql =~ "paradedb.parse_with_field"
      assert sql =~ "lenient => true"
      assert sql =~ "conjunction_mode => true"
      assert sql =~ "paradedb.score"
      assert sql =~ ~s(ORDER BY paradedb.score)
      assert params == ["alpha beta 2", 11]
    end

    test "bm25_query applies source filters after the ParadeDB base query" do
      query = FTSBackend.ParadeDB.bm25_query("alpha beta", 3, ["docs/handbook"])

      {sql, params} = SQL.to_sql(:all, Repo, query)

      assert sql =~ ~s(INNER JOIN "documents")
      assert sql =~ "document_id"
      assert sql =~ "paradedb.parse_with_field"
      assert params == ["alpha beta", "docs/handbook/%", 3]
    end

    @tag :paradedb
    test "bm25_search_group_by builds a sanitized ParadeDB query before execution" do
      Chunk.create_table(1536)

      assert {:ok, %{}} = FTSBackend.ParadeDB.bm25_search_group_by("alpha:(beta)^2", 5)
    end

    @tag :paradedb
    test "bm25_search_group_by includes source filters in the ParadeDB query" do
      Chunk.create_table(1536)

      assert {:ok, %{}} =
               FTSBackend.ParadeDB.bm25_search_group_by("alpha beta", 5, ["docs/handbook"])
    end

    test "fts_count_query sanitizes raw ParadeDB syntax before building the query" do
      query = FTSBackend.ParadeDB.fts_count_query("alpha:(beta)^2", 7)

      {sql, params} = SQL.to_sql(:all, Repo, query)

      assert sql =~ "paradedb.parse_with_field"
      assert sql =~ "LIMIT"
      assert params == ["alpha beta 2", 7]
    end

    test "fts_count_query handles empty sanitized ParadeDB input deterministically" do
      query = FTSBackend.ParadeDB.fts_count_query(" :()^ ", 2)

      {sql, params} = SQL.to_sql(:all, Repo, query)

      assert sql =~ "paradedb.parse_with_field"
      assert params == ["", 2]
    end

    @tag :paradedb
    test "setup_bm25_index attempts to provision the pg_search extension and index" do
      Chunk.create_table(1536)

      assert :ok = FTSBackend.ParadeDB.setup_bm25_index(Repo, 1536)

      assert {:ok, %{rows: [[1]]}} =
               Repo.query("SELECT 1 FROM pg_indexes WHERE indexname = 'chunks_bm25_idx'")
    end
  end
end
