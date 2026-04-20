# Execution Plan: Reimplement BM25 with pg_search (ParadeDB)

**Date:** 2026-04-20
**Author:** Jad
**Status:** `planned`
**Supersedes:** `docs/exec-plans/active/2026-04-18-issue-152-bm25-pg-textsearch.md`
**GitHub issue:** [#152](https://github.com/www-zaq-ai/zaq/issues/152)
**Milestone:** v0.8.x

---

## Goal

Replace the `pg_textsearch` (Timescale) implementation with `pg_search` (ParadeDB).
The reason: `pg_textsearch` has no pre-built Docker image — deployment requires a custom
Dockerfile and `shared_preload_libraries`. `pg_search` ships in `paradedb/paradedb:latest`,
is ParadeDB's core product, and is more mature and actively maintained.

The trade-off accepted: `pg_search` allows only one BM25 index per table, so
the per-language partial index design is dropped. A single index covers all languages;
language scoping is done via `WHERE language = ?` at query time. Per-language stemming
is lost — the `default` tokenizer handles all languages.

---

## Decisions That Change

| Decision (original) | New decision | Why |
|---|---|---|
| Partial indexes per language (`WHERE language = 'xx'`) | Single BM25 index on `chunks` | pg_search enforces one BM25 index per table |
| Indexes created programmatically at runtime | One index created in migration | Nothing to create dynamically anymore |
| ETS registry in `BM25IndexManager` | `BM25IndexManager` gutted to a no-op shell | No per-language index tracking needed |
| `ensure_index(lang)` called per chunk in `insert_chunk` | Call removed | No per-language index to ensure |
| BM25 score is negative (lower = more relevant) | BM25 score is positive (higher = more relevant) | pg_search scores are positive; affects `rrf_merge` sort direction |

## Decisions That Stay (Unchanged)

- Language detection at chunk level via `lingua` NIF — still populates `language` column
- `language` column on `Chunk` — still used for `WHERE language = ?` query-time scoping
- `bm25_search_group_by/2` output shape mirrors `similarity_search_group_by/1`
- Elixir-side RRF fusion via `Task.async`
- Fusion weights (`fusion_bm25_weight`, `fusion_vector_weight`) in LLM config
- `use_bm25` config flag
- GIN tsvector index replaced (not kept alongside)
- Cross-lingual queries handled by vector leg
- `hybrid_search/2` remains retired

---

## Affected Files

| File | Change |
|---|---|
| `docker-compose.yml` | Revert to `paradedb/paradedb:latest`; remove `shared_preload_libraries` command |
| `priv/repo/migrations/20260418000001_add_pg_textsearch_bm25_simple_index.exs` | Extension `pg_textsearch` → `pg_search`; index DDL to pg_search syntax; single index, no `text_config`, no `WHERE` predicate |
| `lib/zaq/ingestion/bm25_index_manager.ex` | Remove ETS registry, `index_exists?/1`, `ensure_index/1`, `index_name/1`; `init/0` becomes a no-op or minimal startup check |
| `lib/zaq/ingestion/document_processor.ex` | `bm25_search_group_by/2`: new query using `@@@` + `paradedb.score(id)`; `rrf_merge/2`: BM25 rank direction `:asc` → `:desc`; `similarity_search_count/1`: update BM25 fragment; `insert_chunk`: remove `BM25IndexManager.ensure_index(lang)` call |
| `test/zaq/ingestion/bm25_index_manager_test.exs` | Rewrite: remove per-language tests; test that `init/0` runs without error and the single index exists |
| `test/zaq/ingestion/bm25_fusion_validation_test.exs` | `assert item.bm25_score < 0` → `assert item.bm25_score > 0`; remove `BM25IndexManager.init()` from setup (or keep as no-op) |

---

## Steps

### Step 1 — `docker-compose.yml`

- Change image: `timescale/timescaledb-ha:pg17-latest` → `paradedb/paradedb:latest`
- Remove `command: postgres -c shared_preload_libraries=...`

---

### Step 2 — Migration `20260418000001`

**`up/0`:**
```sql
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_search;
  DROP INDEX IF EXISTS chunks_content_tsvector_idx;
  CREATE INDEX IF NOT EXISTS chunks_bm25_idx
    ON chunks USING bm25(id, content)
    WITH (key_field='id');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_search setup skipped: %', SQLERRM;
END;
$$
```

**`down/0`:**
```sql
DO $$
BEGIN
  DROP INDEX IF EXISTS chunks_bm25_idx;
  CREATE INDEX IF NOT EXISTS chunks_content_tsvector_idx
    ON chunks USING gin (to_tsvector('english', content));
  DROP EXTENSION IF EXISTS pg_search;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_search rollback skipped: %', SQLERRM;
END;
$$
```

---

### Step 3 — `BM25IndexManager`

Remove entirely and replace with a minimal module. The public API that
`DocumentProcessor` and `Application` reference must still compile:

**Keep (as no-ops or trivial):**
- `init/0` — verify `pg_search` extension exists; log a warning if not.

**Delete:**
- `index_name/1`
- `index_exists?/1`
- `ensure_index/1`
- All ETS table logic (`ensure_ets_table/0`, `register/2`)
- `create_index/1`, `concurrent_index_sql/2`, `sequential_index_sql/2`

---

### Step 4 — `DocumentProcessor.bm25_search_group_by/2`

**Current query (pg_textsearch):**
```elixir
language = LanguageDetector.detect(query_text)
idx = BM25IndexManager.index_name(language)

from(c in Chunk,
  where: c.language == ^language,
  order_by: fragment("content <@> to_bm25query(?::regclass, ?)", ^idx, ^query_text),
  limit: ^limit,
  select: %{
    document_id: c.document_id,
    section_path: c.section_path,
    bm25_score: fragment("content <@> to_bm25query(?::regclass, ?)", ^idx, ^query_text)
  }
)
```

**New query (pg_search):**
```elixir
language = LanguageDetector.detect(query_text)

from(c in Chunk,
  where: c.language == ^language,
  where: fragment("? @@@ paradedb.parse('content'::text, ?::text)", c, ^query_text),
  order_by: [desc: fragment("paradedb.score(?)", c.id)],
  limit: ^limit,
  select: %{
    document_id: c.document_id,
    section_path: c.section_path,
    bm25_score: fragment("paradedb.score(?)", c.id)
  }
)
```

Note: `idx` and `BM25IndexManager.index_name/1` calls are removed entirely.

---

### Step 5 — `DocumentProcessor.rrf_merge/2`

Change BM25 rank direction — positive scores, higher is better:

```elixir
# Before
bm25_ranked = rank_grouped(bm25_grouped, :bm25_score, :asc)

# After
bm25_ranked = rank_grouped(bm25_grouped, :bm25_score, :desc)
```

---

### Step 6 — `DocumentProcessor.similarity_search_count/1`

**Current BM25 branch:**
```elixir
from(c in Chunk,
  where: c.language == ^language,
  where: fragment("content <@> to_bm25query(?::regclass, ?) < 0", ^idx, ^query_text),
  select: %{id: c.id},
  limit: ^limit
)
```

**New BM25 branch:**
```elixir
from(c in Chunk,
  where: c.language == ^language,
  where: fragment("? @@@ paradedb.parse('content'::text, ?::text)", c, ^query_text),
  select: %{id: c.id},
  limit: ^limit
)
```

Remove `idx = BM25IndexManager.index_name(language)` from this function.

---

### Step 7 — `DocumentProcessor.insert_chunk/4`

Remove `BM25IndexManager.ensure_index(lang)` call. Language detection and
column population are unchanged — `language` is still detected and stored:

```elixir
# Before
language =
  if use_bm25?() do
    lang = LanguageDetector.detect(chunk.content)
    BM25IndexManager.ensure_index(lang)
    lang
  end

# After
language =
  if use_bm25?() do
    LanguageDetector.detect(chunk.content)
  end
```

---

### Step 8 — `bm25_index_manager_test.exs`

Replace entirely. New tests:

- `init/0` runs without error
- The `chunks_bm25_idx` index exists in `pg_indexes` after `init/0`
- `init/0` is idempotent (second call does not raise)

Remove:
- All `ensure_index/1` tests
- All `index_exists?/1` tests
- All `index_name/1` tests

---

### Step 9 — `bm25_fusion_validation_test.exs`

- `assert item.bm25_score < 0` → `assert item.bm25_score > 0`
- `setup` block: remove `BM25IndexManager.init()` call (single index already exists from migration; if kept it must be a no-op)

---

### Step 10 — Validate

```bash
MIX_ENV=test mix ecto.reset
mix test --include integration test/zaq/ingestion/bm25_fusion_validation_test.exs
mix test --include integration test/zaq/ingestion/bm25_index_manager_test.exs
mix precommit
```

Manual smoke test:
- Ingest documents in English, French, Arabic
- Verify `language` column is populated correctly per chunk
- Run a query in each language — confirm BM25 results are scoped to that language
- Confirm `rrf_score` values are positive

---

## Definition of Done

- [ ] All 10 steps completed
- [ ] `mix precommit` passes
- [ ] Integration tests green with `paradedb/paradedb:latest`
- [ ] Plan moved to `docs/exec-plans/completed/`
- [ ] Original `2026-04-18` pg_textsearch plan moved to `completed/` (superseded)
