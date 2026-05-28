# Plan: Replace ParadeDB with Native PostgreSQL FTS

**Branch:** `fix/onboarding-path` (or new branch)
**Goal:** Remove the ParadeDB/`pg_search` dependency so ZAQ runs on any managed PostgreSQL (DigitalOcean, Scaleway, or plain `postgres:17`).

---

## Research Summary

### What's supported on managed providers

| Extension | DigitalOcean | Scaleway |
|---|---|---|
| `pg_search` (ParadeDB BM25) | ❌ | ❌ |
| `rum` (PostgresPro) | ✅ | ❌ |
| `pg_trgm` | ✅ | ✅ |
| `unaccent` | ✅ | ✅ |
| Standard FTS (`tsvector`, GIN) | ✅ (built-in) | ✅ (built-in) |
| `pgvector` | ✅ | ✅ |

**Conclusion:** The only portable FTS path across both providers is standard PostgreSQL built-in FTS. No extensions required.

### BM25 scoring strategy

True BM25 requires per-term IDF stats (expensive to compute at query time without a materialized table). However:

- `ts_rank_cd` (Cover Density Ranking) is PostgreSQL's built-in ranking function and a well-established BM25 approximation used in production at scale.
- ZAQ already uses **Reciprocal Rank Fusion (RRF)** to merge BM25 and vector scores. RRF converts absolute scores to ranks before fusion — meaning the exact scoring function (true BM25 vs `ts_rank_cd`) has minimal impact on final retrieval quality.
- `websearch_to_tsquery('english', text)` is injection-safe and supports Google-style syntax (`AND`, `OR`, `-`, `"phrases"`), replacing `paradedb.parse()`.

**Chosen approach:** Standard GIN index on `to_tsvector('english', content)` (expression index — no new column) + `ts_rank_cd` for scoring.

---

## Files to Change

| File | What changes |
|---|---|
| `docker-compose.yml` | `paradedb/paradedb:0.23.0` → `postgres:17`; rename container |
| `priv/repo/migrations/new` | Drop BM25 index + `pg_search`; create GIN expression index |
| `lib/zaq/ingestion/document_processor.ex` | Replace all `paradedb.*` query fragments; rename `sanitize_bm25_query` |
| `lib/zaq/ingestion/chunk.ex` | Update `create_table/0` DDL (used in tests) |
| `test/zaq/ingestion/document_processor_test.exs` | Fix any assertions tied to ParadeDB fragments |

---

## Step-by-Step Implementation

### Step 1 — Docker (`docker-compose.yml`)

```yaml
# Before
paradedb:
  image: paradedb/paradedb:0.23.0
  container_name: zaq-paradedb

# After
postgres:
  image: postgres:17
  container_name: zaq-postgres
```

Also update the default `DATABASE_URL` in the `zaq:` service environment:
```
DATABASE_URL: "${DATABASE_URL:-ecto://postgres:postgres@postgres:5432/zaq_prod}"
```

And update `depends_on:` to reference `postgres` instead of `paradedb`.

---

### Step 2 — Migration

New file: `priv/repo/migrations/20260528000001_replace_paradedb_with_native_fts.exs`

```elixir
defmodule Zaq.Repo.Migrations.ReplaceParadedbWithNativeFts do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      DROP INDEX IF EXISTS chunks_bm25_idx;
      DROP EXTENSION IF EXISTS pg_search;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pg_search cleanup skipped: %', SQLERRM;
    END;
    $$
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS chunks_fts_gin_idx
      ON chunks USING gin(to_tsvector('english', content))
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS chunks_fts_gin_idx")
    # Intentionally do not restore pg_search — that would require ParadeDB
  end
end
```

---

### Step 3 — `document_processor.ex`

Three functions to change:

#### 3a. Rename and simplify `sanitize_bm25_query/1` → `sanitize_fts_query/1`

The existing regex (strip non-word chars, normalize unicode, trim to 512) is still good defensive preprocessing. `websearch_to_tsquery` is already injection-safe, but the sanitizer strips binary junk and enforces length. Keep the body, rename the function and all call sites.

```elixir
# Before
def sanitize_bm25_query(text) do ...

# After
def sanitize_fts_query(text) do ...
```

#### 3b. `bm25_search_group_by/3` — replace query fragments

```elixir
# Before
where: fragment("? @@@ paradedb.parse('content'::text, ?::text)", c, ^safe_query),
order_by: [desc: fragment("paradedb.score(?)", c.id)],
select: %{
  ...
  bm25_score: fragment("paradedb.score(?)", c.id)
}

# After
where: fragment("to_tsvector('english', ?) @@ websearch_to_tsquery('english', ?)", c.content, ^safe_query),
order_by: [desc: fragment("ts_rank_cd(to_tsvector('english', ?), websearch_to_tsquery('english', ?))", c.content, ^safe_query)],
select: %{
  ...
  bm25_score: fragment("ts_rank_cd(to_tsvector('english', ?), websearch_to_tsquery('english', ?))", c.content, ^safe_query)
}
```

Also update the call from `sanitize_bm25_query` → `sanitize_fts_query`.

#### 3c. `fts_count_query/2` — replace fragment

```elixir
# Before
where: fragment("? @@@ paradedb.parse('content'::text, ?::text)", c, ^query_text)

# After
where: fragment("to_tsvector('english', ?) @@ websearch_to_tsquery('english', ?)", c.content, ^query_text)
```

---

### Step 4 — `chunk.ex` `create_table/0`

This function is used in test helpers to set up the chunks table in-process. Replace the ParadeDB DDL:

```elixir
# Remove these two EctoSQL.query! calls:
EctoSQL.query!(Repo, "CREATE EXTENSION IF NOT EXISTS pg_search", [])
EctoSQL.query!(Repo, """
  CREATE INDEX IF NOT EXISTS chunks_bm25_idx
  ON chunks USING bm25(id, content)
  WITH (key_field='id')
""", [])

# Replace with:
EctoSQL.query!(Repo, """
  CREATE INDEX IF NOT EXISTS chunks_fts_gin_idx
  ON chunks USING gin(to_tsvector('english', content))
""", [])
```

---

### Step 5 — Tests

Run `mix test test/zaq/ingestion/document_processor_test.exs` and fix any failures. Likely changes:
- Any mock/assertion referencing `paradedb.parse` or `paradedb.score` SQL fragments
- Check `test/support/e2e/document_processor_fake.ex` for ParadeDB-specific stubs

---

## Validation

```sh
mix format
mix q
mix test test/zaq/ingestion/
mix test test/zaq/ingestion/document_processor_test.exs
```

Smoke-test: ensure hybrid search returns results via BO query with a plain postgres:17 DB.

---

## Notes

- `fusion_bm25_weight` in `LlmConfig` / BO system config UI is a **weight name**, not ParadeDB-specific. It stays as-is — it's just the name for the FTS leg of RRF.
- `dev.exs` and `test.exs` already point to `localhost:5432` (standard Postgres) — no config changes needed there.
- The `websearch_to_tsquery` syntax differs from `paradedb.parse` (Lucene-style vs Google-style). If users were relying on Lucene operators (`field:value`, `~fuzzy`), they'll lose that. In practice ZAQ passes the user's natural language query directly, so this is a non-issue.
- The expression index `to_tsvector('english', content)` hardcodes English. If multi-language support is needed later, replace with a stored generated column using a configurable language — out of scope for this plan.
