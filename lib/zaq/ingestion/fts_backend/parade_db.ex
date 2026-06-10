defmodule Zaq.Ingestion.FTSBackend.ParadeDB do
  @moduledoc """
  ParadeDB full-text search backend.

  Preserves the legacy `pg_search` BM25 query path for existing installations
  that still have the extension installed.
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
        # parse_with_field with conjunction_mode => true gives AND semantics,
        # matching the implicit AND of websearch_to_tsquery in the native
        # backend. lenient => true prevents hard errors on stray syntax
        # characters that survive sanitization.
        where:
          fragment(
            "? @@@ paradedb.parse_with_field('content'::text, ?::text, lenient => true, conjunction_mode => true)",
            c,
            ^safe_query
          ),
        # Tie-break on document/chunk so equal BM25 scores order the same way
        # as the native backend.
        order_by: [
          desc: fragment("paradedb.score(?)", c.id),
          asc: c.document_id,
          asc: c.chunk_index
        ],
        limit: ^limit,
        select: %{
          document_id: c.document_id,
          section_path: c.section_path,
          bm25_score: fragment("paradedb.score(?)", c.id)
        }
      )

    query = FTSBackend.maybe_filter_source(base, source_filter)

    {:ok, FTSBackend.group_results(Repo.all(query))}
  end

  @impl true
  def fts_count_query(query_text, limit) do
    # Sanitize here too — bm25_search_group_by already does, and ParadeDB's
    # query parser can raise on raw special syntax (AND, OR, :, ^, parens).
    safe_query = sanitize_query(query_text)

    from(c in Chunk,
      where:
        fragment(
          "? @@@ paradedb.parse_with_field('content'::text, ?::text, lenient => true, conjunction_mode => true)",
          c,
          ^safe_query
        ),
      select: %{id: c.id},
      limit: ^limit
    )
  end

  @impl true
  def setup_bm25_index(repo, _dimension) do
    SQL.query!(repo, "CREATE EXTENSION IF NOT EXISTS pg_search", [])

    SQL.query!(
      repo,
      """
      CREATE INDEX IF NOT EXISTS chunks_bm25_idx
        ON chunks USING bm25(id, content)
        WITH (key_field='id')
      """,
      []
    )

    :ok
  end
end
