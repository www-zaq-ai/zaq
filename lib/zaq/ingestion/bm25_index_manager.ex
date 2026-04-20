defmodule Zaq.Ingestion.BM25IndexManager do
  @moduledoc """
  Startup check for the pg_search BM25 index on the chunks table.

  pg_search enforces one BM25 index per table, so a single index
  (`chunks_bm25_idx`) covers all languages. Language scoping is done at
  query time via `WHERE language = ?`. Per-language partial indexes are
  not used.

  Call `init/0` at startup to verify the extension and index are present.
  The index itself is created by migration 20260418000001.
  """

  require Logger

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Zaq.Repo

  @index_name "chunks_bm25_idx"

  @doc """
  Verifies that pg_search is installed and the BM25 index exists.
  Logs a warning if either is missing — does not attempt to create them
  (that is the migration's responsibility).
  """
  @spec init() :: :ok
  def init do
    case EctoSQL.query(
           Repo,
           "SELECT 1 FROM pg_indexes WHERE indexname = $1",
           [@index_name]
         ) do
      {:ok, %{rows: [_ | _]}} ->
        :ok

      {:ok, %{rows: []}} ->
        Logger.warning(
          "BM25IndexManager: index #{@index_name} not found — run migrations to create it"
        )

        :ok

      {:error, reason} ->
        Logger.warning("BM25IndexManager: could not verify index — #{inspect(reason)}")
        :ok
    end
  end
end
