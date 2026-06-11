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
    opts = if Repo.in_transaction?(), do: [mode: :savepoint], else: []

    Repo
    |> SQL.query("SELECT 1 FROM paradedb.version_info()", [], opts)
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
  Sanitizes free-form user input for PostgreSQL full-text query functions.
  """
  def sanitize_query_text(text) do
    text
    |> sanitize_utf8_text()
    |> unicode_normalize()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.replace(~r/ {2,}/, " ")
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
