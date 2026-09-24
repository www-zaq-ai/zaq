defmodule Zaq.Repo.Migrations.RebuildMultilingualContentTsv do
  use Ecto.Migration

  @moduledoc """
  Rebuilds native full-text vectors from the installed text-search configurations.
  A generated column snapshots the configuration mapping in an immutable CASE
  expression; unsupported or undetected languages use pg_catalog.simple. The
  BM25 index is independent and remains intact. This rewrite locks chunks;
  schedule it accordingly on large installations.
  """

  def up, do: execute(up_sql())

  @doc false
  def up_sql do
    """
    DO $$
    DECLARE language_cases text;
    BEGIN
      IF to_regclass('public.chunks') IS NOT NULL THEN
        SELECT COALESCE(string_agg(
          format(' WHEN %L THEN %L::regconfig', name, qualified_name), ' '
          ORDER BY name
        ), '') INTO language_cases
        FROM (
          SELECT DISTINCT ON (c.cfgname) c.cfgname AS name,
            format('%I.%I', n.nspname, c.cfgname) AS qualified_name
          FROM pg_catalog.pg_ts_config c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.cfgnamespace
          WHERE n.nspname IN ('pg_catalog', 'public') AND c.cfgname <> 'simple'
          ORDER BY c.cfgname, (n.nspname = 'pg_catalog') DESC
        ) configs;

        DROP INDEX IF EXISTS chunks_content_tsv_idx;
        ALTER TABLE chunks DROP COLUMN IF EXISTS content_tsv;
        EXECUTE format('ALTER TABLE chunks ADD COLUMN content_tsv tsvector GENERATED ALWAYS AS (to_tsvector(CASE language %s ELSE ''pg_catalog.simple''::regconfig END, content)) STORED', language_cases);
        CREATE INDEX chunks_content_tsv_idx ON chunks USING gin(content_tsv);
      END IF;
    END;
    $$
    """
  end

  def down, do: execute(down_sql())

  @doc false
  def down_sql do
    """
    DO $$
    BEGIN
      IF to_regclass('public.chunks') IS NOT NULL THEN
        DROP INDEX IF EXISTS chunks_content_tsv_idx;
        ALTER TABLE chunks DROP COLUMN IF EXISTS content_tsv;
        ALTER TABLE chunks ADD COLUMN content_tsv tsvector
          GENERATED ALWAYS AS (to_tsvector('english'::regconfig, content)) STORED;
        CREATE INDEX chunks_content_tsv_idx ON chunks USING gin(content_tsv);
      END IF;
    END;
    $$
    """
  end
end
