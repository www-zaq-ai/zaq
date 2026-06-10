defmodule Zaq.Ingestion.FTSBackend.Native do
  @moduledoc """
  Native PostgreSQL full-text search backend.

  Uses a stored `content_tsv` column, a GIN index, `websearch_to_tsquery/2`, and
  `ts_rank_cd/2` to provide the same grouped result shape as the legacy BM25 path.
  """

  @behaviour Zaq.Ingestion.FTSBackend

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Zaq.Ingestion.{Chunk, FTSBackend}
  alias Zaq.Repo

  @impl true
  def sanitize_query(text) do
    FTSBackend.sanitize_query_text(text)
  end

  @impl true
  def bm25_search_group_by(query_text, limit, source_filter \\ []) do
    safe_query = sanitize_query(query_text)

    base =
      from(c in Chunk,
        where: fragment("content_tsv @@ websearch_to_tsquery('english', ?)", ^safe_query),
        # ts_rank_cd produces frequent ties; without the secondary keys the row
        # set and order under LIMIT are nondeterministic across runs/backends.
        order_by: [
          desc:
            fragment("ts_rank_cd(content_tsv, websearch_to_tsquery('english', ?))", ^safe_query),
          asc: c.document_id,
          asc: c.chunk_index
        ],
        limit: ^limit,
        select: %{
          document_id: c.document_id,
          section_path: c.section_path,
          bm25_score:
            fragment("ts_rank_cd(content_tsv, websearch_to_tsquery('english', ?))", ^safe_query)
        }
      )

    query = FTSBackend.maybe_filter_source(base, source_filter)

    {:ok, FTSBackend.group_results(Repo.all(query))}
  end

  @impl true
  def fts_count_query(query_text, limit) do
    from(c in Chunk,
      where: fragment("content_tsv @@ websearch_to_tsquery('english', ?)", ^query_text),
      select: %{id: c.id},
      limit: ^limit
    )
  end

  @impl true
  def setup_bm25_index(repo, _dimension) do
    SQL.query!(
      repo,
      """
      ALTER TABLE chunks
        ADD COLUMN IF NOT EXISTS content_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('english', content)) STORED
      """,
      []
    )

    SQL.query!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS chunks_content_tsv_idx
      ON chunks USING gin(content_tsv)
      """,
      []
    )

    :ok
  end
end
