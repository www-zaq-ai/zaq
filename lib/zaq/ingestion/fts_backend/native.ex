defmodule Zaq.Ingestion.FTSBackend.Native do
  @moduledoc """
  Native PostgreSQL full-text search backend.

  Uses a language-aware stored `content_tsv` column, one GIN index,
  `websearch_to_tsquery/2`, and `ts_rank_cd/2`. The generated expression
  snapshots installed text-search configurations at table creation; installing
  additional configurations requires rebuilding the generated column.
  """

  @behaviour Zaq.Ingestion.FTSBackend

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Zaq.Ingestion.{Chunk, FTSBackend}
  alias Zaq.Repo

  @impl true
  def sanitize_query(text) do
    # websearch_to_tsquery is injection-safe and tokenizes the query the same way
    # to_tsvector tokenized the content, so only minimal sanitization is needed
    # (preserves IPs/versions/emails). See FTSBackend.sanitize_query_minimal/1.
    FTSBackend.sanitize_query_minimal(text)
  end

  @impl true
  def bm25_search_group_by(query_text, limit, source_filter \\ [], language \\ nil) do
    safe_query = if is_list(query_text), do: query_text, else: sanitize_query(query_text)

    rows =
      case language do
        nil ->
          indexed_languages()
          |> Enum.flat_map(fn indexed_language ->
            indexed_language
            |> search_query(safe_query, limit, source_filter)
            |> Repo.all()
          end)
          |> Enum.sort_by(fn row ->
            {-row.bm25_score, row.document_id, row.chunk_index}
          end)
          |> Enum.take(limit)

        language ->
          language
          |> search_query(safe_query, limit, source_filter)
          |> Repo.all()
      end

    {:ok, FTSBackend.group_results(rows)}
  end

  defp search_query(language, safe_query, limit, source_filter) do
    config = configuration_for(language)

    {predicate, rank} =
      case safe_query do
        terms when is_list(terms) ->
          Enum.reduce(terms, {dynamic(false), dynamic(0.0)}, fn term, {matches, score} ->
            # plainto_tsquery interprets each term as data and ANDs its
            # analyzed words; OR across independently generated clauses.
            clause =
              dynamic(
                [c],
                fragment("content_tsv @@ plainto_tsquery(?::text::regconfig, ?)", ^config, ^term)
              )

            term_rank =
              dynamic(
                [c],
                fragment(
                  "ts_rank_cd(content_tsv, plainto_tsquery(?::text::regconfig, ?))",
                  ^config,
                  ^term
                )
              )

            {dynamic([c], ^matches or ^clause), dynamic([c], ^score + ^term_rank)}
          end)

        text ->
          {
            dynamic(
              [c],
              fragment(
                "content_tsv @@ websearch_to_tsquery(?::text::regconfig, ?)",
                ^config,
                ^text
              )
            ),
            dynamic(
              [c],
              fragment(
                "ts_rank_cd(content_tsv, websearch_to_tsquery(?::text::regconfig, ?))",
                ^config,
                ^text
              )
            )
          }
      end

    projection =
      dynamic([c], %{
        document_id: c.document_id,
        section_path: c.section_path,
        chunk_index: c.chunk_index,
        bm25_score: ^rank
      })

    base =
      from(c in Chunk, where: ^predicate)
      # ts_rank_cd produces frequent ties; keep deterministic tie-breaks.
      |> order_by(^[desc: rank, asc: :document_id, asc: :chunk_index])
      |> limit(^limit)
      |> select(^projection)

    base =
      if is_nil(language) do
        where(base, [c], is_nil(c.language))
      else
        FTSBackend.maybe_filter_language(base, language)
      end

    FTSBackend.maybe_filter_source(base, source_filter)
  end

  defp indexed_languages do
    Repo.all(from(c in Chunk, distinct: true, select: c.language))
  end

  @doc "Returns the installed text-search configuration for a detected language, or simple."
  def configuration_for(nil), do: "pg_catalog.simple"
  def configuration_for("simple"), do: "pg_catalog.simple"

  def configuration_for(language) when is_binary(language) do
    case SQL.query!(
           Repo,
           """
           SELECT format('%I.%I', n.nspname, c.cfgname)
           FROM pg_catalog.pg_ts_config c
           JOIN pg_catalog.pg_namespace n ON n.oid = c.cfgnamespace
           WHERE c.cfgname = $1 AND n.nspname IN ('pg_catalog', 'public')
           ORDER BY (n.nspname = 'pg_catalog') DESC
           LIMIT 1
           """,
           [language]
         ) do
      %{rows: [[config]]} -> config
      _ -> "pg_catalog.simple"
    end
  end

  @impl true
  def fts_count_query(query_text, limit) do
    safe_query = sanitize_query(query_text)

    predicate =
      Enum.reduce(indexed_languages(), dynamic(false), fn language, predicate ->
        config = configuration_for(language)

        language_match =
          if is_nil(language) do
            dynamic([c], is_nil(c.language))
          else
            dynamic([c], c.language == ^language)
          end

        dynamic(
          [c],
          ^predicate or
            (^language_match and
               fragment(
                 "content_tsv @@ websearch_to_tsquery(?::text::regconfig, ?)",
                 ^config,
                 ^safe_query
               ))
        )
      end)

    from(c in Chunk,
      where: ^predicate,
      select: %{id: c.id},
      limit: ^limit
    )
  end

  @impl true
  def setup_bm25_index(repo, _dimension) do
    # The catalog is the source of truth across supported PostgreSQL versions.
    # Have PostgreSQL quote identifiers and string literals; never interpolate
    # untrusted language identifiers into DDL ourselves.
    %{rows: [[cases]]} =
      SQL.query!(
        repo,
        """
        SELECT COALESCE(string_agg(
          format(' WHEN %L THEN %L::regconfig', name, qualified_name), ' '
          ORDER BY name
        ), '')
        FROM (
          SELECT DISTINCT ON (c.cfgname) c.cfgname AS name,
            format('%I.%I', n.nspname, c.cfgname) AS qualified_name
          FROM pg_catalog.pg_ts_config c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.cfgnamespace
          WHERE n.nspname IN ('pg_catalog', 'public') AND c.cfgname <> 'simple'
          ORDER BY c.cfgname, (n.nspname = 'pg_catalog') DESC
        ) configs
        """,
        []
      )

    SQL.query!(
      repo,
      """
      ALTER TABLE chunks
        ADD COLUMN IF NOT EXISTS content_tsv tsvector
        GENERATED ALWAYS AS (
          to_tsvector(CASE language #{cases} ELSE 'pg_catalog.simple'::regconfig END, content)
        ) STORED
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
