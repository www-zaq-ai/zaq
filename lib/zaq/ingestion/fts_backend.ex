defmodule Zaq.Ingestion.FTSBackend do
  @moduledoc """
  Behaviour and runtime detector for pluggable full-text search backends.

  The active backend is detected once at application startup and cached in
  `:persistent_term`, keeping search calls free of database probes.

  ## Caching: `:persistent_term` vs ETS

  `:persistent_term` is optimised for read-mostly data: lookups are
  constant-time with no copying, but every update forces a global GC pass
  across all processes. ETS is the right tool when the cached value changes
  often — updates are cheap and isolated, at the cost of a copy on every
  read. The detected backend is written once at startup and read on every
  search call, which is exactly the write-once/read-hot profile
  `:persistent_term` is built for. If this cache ever needs frequent
  updates, move it to ETS instead.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Zaq.Ingestion.{Document, DocumentAccess}
  alias Zaq.Repo

  require Logger

  @callback bm25_search_group_by(String.t(), pos_integer(), list()) ::
              {:ok, map()} | {:error, term()}
  @callback fts_count_query(String.t(), pos_integer()) :: Ecto.Query.t()
  @callback sanitize_query(String.t()) :: String.t()
  @callback setup_bm25_index(module(), pos_integer()) :: :ok

  @cache_key {__MODULE__, :backend}

  @doc "Returns the cached active backend module."
  def impl do
    case :persistent_term.get(@cache_key, nil) do
      nil -> detect_and_cache()
      backend -> backend
    end
  end

  @doc """
  Detects whether a working ParadeDB installation is present and caches the
  active backend.

  Detection is functional, not catalog-based: `paradedb.version_info()` only
  succeeds when the pg_search binary is actually loaded and callable — a
  `pg_extension` catalog row can disagree with what is really installed
  (partial upgrades, forked or patched builds).

  On a functional ParadeDB server the choice then depends on table state:

    * `chunks_bm25_idx` exists → ParadeDB.
    * no chunks table yet (fresh install) → ParadeDB. Nothing can be
      searched before the table exists, and `setup_index/2` creates the
      BM25 index together with the table, so the promise is self-fulfilling
      from the first boot.
    * chunks table without the index (legacy table created while the
      extension was absent or broken) → Native, because the ParadeDB
      backend's `@@@` queries error without the index.
  """
  def detect_and_cache do
    backend =
      if paradedb_functional?() and (bm25_index_present?() or not chunks_table_exists?()) do
        __MODULE__.ParadeDB
      else
        __MODULE__.Native
      end

    :persistent_term.put(@cache_key, backend)
    Logger.info("[FTSBackend] active backend: #{inspect(backend)}")
    backend
  end

  @doc """
  Provisions FTS indexes for a freshly created chunks table and re-detects
  the active backend.

  Dispatches on the functional probe rather than the cached backend: on a
  fresh install the cache necessarily holds Native (`chunks_bm25_idx` cannot
  exist before the chunks table does), so dispatching on `impl/0` would lock
  the ParadeDB backend out forever.

  The native column and index are always created — they are the universal
  fallback and migration `20260528000001` expects `content_tsv` on ParadeDB
  deployments too. The BM25 index is added on top when pg_search is
  functional, and re-detection then switches the cache to ParadeDB.
  """
  def setup_index(repo, dimension) do
    __MODULE__.Native.setup_bm25_index(repo, dimension)

    if paradedb_functional?() do
      __MODULE__.ParadeDB.setup_bm25_index(repo, dimension)
    end

    # detect_and_cache/0 overwrites the cached entry unconditionally, so no
    # reset_cache/0 first — erase + put would mean two global GC passes.
    detect_and_cache()
    :ok
  end

  defp paradedb_functional? do
    version_info_in_catalog?() and version_info_callable?()
  end

  @doc """
  Startup self-heal that converges the connected database to a working ParadeDB
  install. Decides what to do from `pg_available_extensions`:

    * `:absent` — pg_search not on this server (plain Postgres). Nothing to do;
      Native is correct.
    * `:uninstalled` — the binary is preloaded (extension *available*) but was
      never `CREATE EXTENSION`-d in this database (e.g. a ZAQ database created
      separately from the image's default `paradedb` database). Create it.
    * `:stale` — installed in this database but at an older version than the
      loaded library (e.g. the image was upgraded without updating the
      extension). `ALTER EXTENSION ... UPDATE` it. This is the case that breaks
      `paradedb.version_info()` and `pg_dump`.
    * `:current` — already up to date. Nothing to do.

  After healing (which also provisions the BM25 index on a pre-existing chunks
  table) it re-detects. If detection still resolves to Native while the
  extension is installed, search is running degraded for a reason ZAQ cannot fix
  itself — almost always the library is not loaded via
  `shared_preload_libraries` — so it logs a loud, actionable warning.

  This runs DDL, so it is intentionally **not** part of the detection path:
  `detect_and_cache/0` and `impl/0` stay side-effect-free and safe to call on
  any node and inside any transaction. Call this exactly once at startup from
  the single node that owns ingestion (see the application start callback),
  never from a request or a lazy cache miss — a BM25 index build on a populated
  table is heavy and must not block search.

  All DDL is savepoint-protected so a failure (a server where the binary is not
  actually loadable, or plain Postgres that merely ships the control file) rolls
  back without aborting an enclosing transaction. Returns the freshly detected
  backend.
  """
  def self_heal do
    heal_pg_search(pg_search_state())
    backend = detect_and_cache()
    warn_if_degraded(backend, pg_search_extension_installed?())
    backend
  end

  defp pg_search_state do
    Repo
    |> SQL.query(
      """
      SELECT installed_version, default_version
      FROM pg_available_extensions
      WHERE name = 'pg_search'
      LIMIT 1
      """,
      []
    )
    |> pg_search_state_from()
  end

  @doc """
  Maps a `pg_available_extensions` probe for pg_search to the heal action the
  connected database needs. Public so the decision is unit-testable without a
  stale extension on disk.
  """
  def pg_search_state_from({:ok, %{rows: [[nil, _default]]}}), do: :uninstalled
  def pg_search_state_from({:ok, %{rows: [[version, version]]}}), do: :current
  def pg_search_state_from({:ok, %{rows: [[_installed, _default]]}}), do: :stale
  def pg_search_state_from(_result), do: :absent

  defp heal_pg_search(state) do
    case heal_command(state) do
      {sql, action} -> run_extension_heal(sql, action)
      :noop -> :ok
    end
  end

  @doc """
  Maps a pg_search state to the DDL + log label needed to heal it, or `:noop`
  for `:absent` (plain Postgres) and `:current` (already up to date). Public so
  the `:stale` upgrade path is unit-testable without a stale extension on disk.
  """
  def heal_command(:uninstalled), do: {"CREATE EXTENSION IF NOT EXISTS pg_search", "created"}

  def heal_command(:stale),
    do: {"ALTER EXTENSION pg_search UPDATE", "updated to the current version"}

  def heal_command(_state), do: :noop

  defp run_extension_heal(sql, action) do
    opts = savepoint_opts()

    Repo
    |> SQL.query(sql, [], opts)
    |> heal_extension_result(opts, action)
  end

  @doc """
  Handles a self-heal DDL result: on success provisions the BM25 index on a
  pre-existing chunks table and logs the action taken, on failure logs and skips
  so a server whose pg_search binary is not actually loadable falls through to
  Native. Public for direct testing of the failure branch, which cannot be
  triggered against a live ParadeDB where the DDL always succeeds.
  """
  def heal_extension_result({:ok, _result}, opts, action) do
    maybe_create_bm25_index(opts)
    Logger.info("[FTSBackend] self-healed pg_search in the connected database (#{action})")
  end

  def heal_extension_result({:error, reason}, _opts, _action) do
    Logger.debug(fn ->
      "[FTSBackend] pg_search self-heal skipped (DDL failed): #{inspect(reason)}"
    end)

    :ok
  end

  @doc """
  Warns when pg_search is installed in the connected database but search still
  fell back to Native — a degraded state ZAQ cannot self-heal (the library is
  not loaded by Postgres). Public so the warning matrix is unit-testable.
  """
  def warn_if_degraded(backend, true = _extension_installed?) when backend == __MODULE__.Native do
    Logger.warning(
      "[FTSBackend] pg_search is installed but not functional — search is running in " <>
        "degraded (Native) mode. This usually means the pg_search library is not loaded by " <>
        "Postgres. Add 'pg_search' to shared_preload_libraries in postgresql.conf, restart " <>
        "Postgres, then run: ALTER EXTENSION pg_search UPDATE;"
    )
  end

  def warn_if_degraded(_backend, _extension_installed?), do: :ok

  # A legacy chunks table created while the extension was absent has no BM25
  # index; without it the ParadeDB backend would still lose to Native. A fresh
  # install has no chunks table yet — detection selects ParadeDB anyway, and
  # `setup_index/2` provisions the index when the table is later created.
  defp maybe_create_bm25_index(opts) do
    if chunks_table_exists?() and not bm25_index_present?() do
      SQL.query(Repo, __MODULE__.ParadeDB.bm25_index_ddl(), [], opts)
    end

    :ok
  end

  defp pg_search_extension_installed? do
    Repo
    |> SQL.query("SELECT 1 FROM pg_extension WHERE extname = 'pg_search' LIMIT 1", [])
    |> rows_present?()
  end

  # Savepoint mode only matters inside an open transaction (test sandbox,
  # Ecto.Multi, a request that lazily triggers detection); outside one it is a
  # no-op. Shared by the version probe and the self-heal so both stay safe to
  # run mid-transaction.
  defp savepoint_opts do
    if Repo.in_transaction?(), do: [mode: :savepoint], else: []
  end

  # Catalog pre-check that can never raise a SQL error: detection may run
  # inside an open transaction (Ecto.Multi, test sandbox), and a failed
  # statement would abort it (25P02) even when the error itself is handled.
  defp version_info_in_catalog? do
    SQL.query(
      Repo,
      """
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'paradedb' AND p.proname = 'version_info'
      LIMIT 1
      """,
      []
    )
    |> rows_present?()
  end

  # Executing the function proves the pg_search binary is loaded — a catalog
  # row alone cannot. The savepoint keeps a failure (e.g. a forked build with
  # a stale catalog entry) from aborting an enclosing transaction.
  defp version_info_callable? do
    Repo
    |> SQL.query("SELECT 1 FROM paradedb.version_info()", [], savepoint_opts())
    |> callable_probe_result()
  end

  # Deliberately not Chunk.table_exists?/0 — that raises on query errors,
  # while detection probes must never raise (they may run inside an open
  # transaction at any point of the app lifecycle).
  defp chunks_table_exists? do
    SQL.query(
      Repo,
      """
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = 'chunks'
      """,
      []
    )
    |> rows_present?()
  end

  defp bm25_index_present? do
    SQL.query(
      Repo,
      "SELECT 1 FROM pg_indexes WHERE indexname = 'chunks_bm25_idx' LIMIT 1",
      []
    )
    |> rows_present?()
  end

  @doc "Returns true when a SQL query result contains at least one row."
  def rows_present?({:ok, %{rows: [_ | _]}}), do: true
  def rows_present?(_result), do: false

  @doc "Returns whether the ParadeDB version probe completed successfully."
  def callable_probe_result({:ok, _result}), do: true

  def callable_probe_result({:error, reason}) do
    Logger.debug(fn ->
      "[FTSBackend] paradedb.version_info() not callable, using native: #{inspect(reason)}"
    end)

    false
  end

  @doc "Clears the cached backend. Use in tests or after extension changes."
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Aggressive sanitization that neutralizes query-language operators for the
  ParadeDB/tantivy backend (`parse_with_field`), which interprets characters such
  as `:`, `^`, `(`, `)` as syntax. Strips all punctuation except dots that sit
  between alphanumerics, so dotted literals (IPv4 `10.0.0.42`, versions `1.2.3`,
  decimals) survive as single tokens.

  The Native (PostgreSQL) backend does NOT use this — `websearch_to_tsquery/2` is
  injection-safe and tokenizes identically to `to_tsvector`, so it only needs
  `sanitize_query_minimal/1`.
  """
  def sanitize_query_text(text) do
    text
    |> sanitize_utf8_text()
    |> unicode_normalize()
    |> strip_punctuation_keep_dotted_literals()
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
    |> String.slice(0, 512)
  end

  @doc """
  Minimal, security-only sanitization for PostgreSQL `websearch_to_tsquery/2`.

  `websearch_to_tsquery` never errors on user input and applies the same parser
  as `to_tsvector` at index time, so the query must NOT be pre-tokenized. We only
  strip invalid/null bytes, normalize unicode, collapse whitespace and cap length
  — preserving IPs, versions, emails and phrases so the query tokenizes the same
  way the indexed content did (analyzer symmetry).
  """
  def sanitize_query_minimal(text) do
    text
    |> sanitize_utf8_text()
    |> unicode_normalize()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 512)
  end

  @doc """
  Removes invalid UTF-8 bytes and null bytes while preserving document content.
  """
  def sanitize_utf8_text(binary), do: sanitize_utf8(binary, [])

  @doc """
  Adds the shared document source filter join to a backend search query.
  """
  def maybe_filter_source(query, []), do: query

  def maybe_filter_source(query, source_filter) do
    query
    |> join(:inner, [c], d in Document, on: c.document_id == d.id, as: :doc)
    |> where(^DocumentAccess.build_source_filter_condition(source_filter))
  end

  @doc """
  Groups flat backend search rows by document ID and section path.
  """
  def group_results(results) do
    results
    |> Enum.group_by(& &1.document_id)
    |> Map.new(fn {doc_id, items} ->
      {doc_id, Enum.group_by(items, & &1.section_path)}
    end)
  end

  # Strips query-language punctuation while keeping dots that sit between
  # alphanumerics, so dotted literals (IPv4 "10.0.0.42", versions "1.2.3",
  # decimals) survive as single tokens.
  defp strip_punctuation_keep_dotted_literals(text) do
    text
    # Collapse runs of disallowed characters to a space, but KEEP dots so dotted
    # literals are not shattered into separate tokens — that mismatch is why a raw
    # IP query never matched the single FTS token produced by to_tsvector.
    |> String.replace(~r/[^\p{L}\p{N}.]+/u, " ")
    # Drop dots that are not flanked by alphanumerics on both sides (leading,
    # trailing, or standalone), so only intra-token dots survive.
    |> String.replace(~r/(?<![\p{L}\p{N}])\.+|\.+(?![\p{L}\p{N}])/u, " ")
  end

  defp unicode_normalize(text) do
    case :unicode.characters_to_nfc_binary(text) do
      normalized when is_binary(normalized) -> normalized
      _ -> text
    end
  end

  defp sanitize_utf8(<<0, rest::binary>>, acc), do: sanitize_utf8(rest, acc)
  defp sanitize_utf8(<<>>, acc), do: IO.iodata_to_binary(:lists.reverse(acc))
  defp sanitize_utf8(<<c::utf8, rest::binary>>, acc), do: sanitize_utf8(rest, [<<c::utf8>> | acc])
  defp sanitize_utf8(<<_::8, rest::binary>>, acc), do: sanitize_utf8(rest, acc)
end
