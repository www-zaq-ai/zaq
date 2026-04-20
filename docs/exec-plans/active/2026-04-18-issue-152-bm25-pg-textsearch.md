# Execution Plan: Replace Hybrid Search with BM25 via pg_textsearch

## Plan: BM25 Full-Text Search via pg_textsearch

**Date:** 2026-04-18
**Author:** Jad
**Status:** `in-progress` (Steps 0–19 done; Steps 8, 20, 21 remain)
**Related debt:** —
**PR(s):** —
**GitHub issue:** [#152](https://github.com/www-zaq-ai/zaq/issues/152)
**Milestone:** v0.8.x

---

## Goal

Replace the current `tsvector`/`ts_rank` full-text search leg of hybrid search with BM25
scoring via the `pg_textsearch` PostgreSQL extension (Timescale). BM25 scoring is more
accurate than `ts_rank` for relevance ranking and supports multilingual configs natively.
The change is scoped to the FTS leg — the vector leg (pgvector) is unchanged. The existing
`hybrid_search/2` (monolithic SQL RRF) is retired; replaced by a parallel `Task.async`
approach where `bm25_search_group_by/2` and `similarity_search_group_by/1` run concurrently
and are fused in Elixir via `rrf_merge/2` before feeding the existing `query_extraction/2`
downstream pipeline.

Done looks like: retrieval uses BM25+vector RRF for BO and channel queries; language is
detected per-chunk at ingestion time; per-language partial BM25 indexes are created
programmatically as new languages are encountered; a `simple` fallback index covers
languages without a dedicated config; retrieval quality is validated against the previous
implementation.

---

## Context

- [x] `docs/services/ingestion.md`
- [x] `docs/architecture.md`
- [x] `docs/services/engine.md`
- [x] Existing code reviewed:
  - `lib/zaq/ingestion/document_processor.ex` — `hybrid_search/2` (lines ~857–977), `similarity_search_group_by/1` (lines ~782–805), `query_extraction/2` (lines ~741–752)
  - `lib/zaq/ingestion/chunk.ex` — existing GIN tsvector index and HNSW vector index
  - `lib/zaq/agent/pipeline.ex` — calls `DocumentProcessor.query_extraction/2` (vector-only today)
  - `lib/zaq/system/ingestion_config.ex` — `distance_threshold`, `hybrid_search_limit`, `max_context_window`
  - `priv/repo/migrations/` — existing FTS and vector migration history
- [x] `pg_textsearch` README reviewed — v1.0.0, production ready; partial indexes for multilingual tables are the documented canonical pattern

### Current state summary

| What | How |
|---|---|
| FTS query | `to_tsvector('english', content) @@ plainto_tsquery('english', ?)` |
| FTS ranking | `ts_rank(to_tsvector('english', content), plainto_tsquery('english', ?))` |
| FTS index | GIN on `to_tsvector('english', content)` |
| Hybrid fusion | Reciprocal Rank Fusion (k=60) over FTS + vector legs |
| Pipeline path | `query_extraction` → **vector-only** `similarity_search_group_by` (hybrid_search not wired in) |
| Language | Hardcoded `'english'` everywhere, no language field on Chunk; detection happens at neither document nor chunk level |

### Risk factors

- Requires PostgreSQL 17 or 18 — must confirm deployment target.
- Operator `<@>` syntax differs from `@@`; Ecto fragments need updating.
- Partial indexes require explicit index naming via `to_bm25query/2` — implicit `<@>` shorthand skips them.
- `bm25_force_merge` must be run after initial data load for best performance.

---

## Approach

1. Install `pg_textsearch` at the infrastructure level (Docker image / PostgreSQL config).
2. Enable the extension and drop the existing GIN tsvector index via a migration.
3. Add a `language` field to `Chunk`; detect language per-chunk at ingestion time using `lingua`.
4. Create BM25 partial indexes programmatically — one per language as they are first encountered, each scoped with `WHERE language = 'xx'`. A `simple` fallback index covers unsupported languages.
5. Write `bm25_search_group_by/2` — mirrors the grouped output of `similarity_search_group_by/1` so both legs produce the same shape.
6. In `query_extraction/2`, run both legs in parallel via `Task.async`, then fuse with `rrf_merge/2`.
7. Add startup self-heal to recreate any missing indexes on fresh deployments.
8. Validate retrieval quality before shipping.

The GIN tsvector index is replaced (not kept alongside) to avoid dual-maintenance. If a
rollback is needed, the migration can drop the BM25 indexes and recreate the GIN.

Language indexes are **not** added via migration files — they are created dynamically at
runtime as new languages are encountered. This is the documented pattern for multilingual
tables in `pg_textsearch` and avoids requiring a deployment for every new language.

**Fusion design** — `similarity_search_group_by/1` is left completely unchanged. Instead,
`bm25_search_group_by/2` returns results in the identical grouped shape:
`%{doc_id => %{section_path => [%{document_id, section_path, bm25_score}]}}`.
`rrf_merge/2` takes both maps, unions all `{doc_id, section_path}` keys, and scores each
section using weighted RRF (k=60):
`fusion_bm25_weight * 1/(60 + bm25_rank) + fusion_vector_weight * 1/(60 + vector_rank)`,
with 0 contribution from whichever leg did not surface that section. Both weights default
to 0.5 and are tunable at runtime via LLM config. The merged map feeds directly into the
existing `build_query_sections` → `fetch_sections_with_source` → `limit_to_context_window`
pipeline — nothing downstream changes. `hybrid_search/2` (the old monolithic SQL approach)
is retired as dead code.

---

## Steps

### Phase 0 — Clean

- [x] Step 0: **Remove `hybrid_search/2` tests** — Deleted 4 test blocks from `document_processor_test.exs`. Suite green (63 tests) before writing new tests.

---

### Phase 1 — Red (write all failing tests first)

- [x] Step 1: **Language detection tests** — `test/zaq/ingestion/language_detector_test.exs` (6 tests, all pass with lingua NIF).

- [x] Step 2: **Programmatic index creation tests** — `test/zaq/ingestion/bm25_index_manager_test.exs` (tagged `:integration`, excluded from default run).

- [x] Step 3: **`bm25_search_group_by/2` tests** — Appended to `document_processor_test.exs` (tagged `:integration`).

- [x] Step 4: **`rrf_merge/2` tests** — 6 unit tests in `document_processor_test.exs`, all passing.

- [x] Step 5: **`similarity_search_count/1` tests** — Integration-tagged test added.

- [x] Step 6: **`query_extraction/2` integration tests** — 3 tests (2 integration, 1 unit for `use_bm25: false` fallback).

- [x] Step 7: **Retrieval quality regression test** — Integration-tagged test added.

---

### Phase 2 — Green (implement to pass)

- [ ] Step 8: **Infra** — Confirm PostgreSQL 17+ on all deployment targets. Update Docker base image if needed. Add `shared_preload_libraries = 'pg_textsearch'` to PostgreSQL config.

- [x] Step 9: **Extension + initial index migration** — `priv/repo/migrations/20260418000001_add_pg_textsearch_bm25_simple_index.exs`. Wrapped in DO/EXCEPTION block for graceful fallback on PG < 17.

- [x] Step 10: **Language field + backfill** — `priv/repo/migrations/20260418000002_add_language_to_chunks.exs`. Also updated `Chunk.create_table/1` to include `language` column (handles post-reset_ingestion recreations). `Chunk` schema updated.

- [x] Step 11: **Per-chunk language detection** — `lib/zaq/ingestion/language_detector.ex`. Uses `lingua ~> 0.3.6` (rustler_precompiled NIF). Confidence ≥ 0.8 + ≥ 20 tokens → pg_textsearch config name; else `"simple"`. Guarded by `use_bm25?()` in `insert_chunk/4`.

- [x] Step 12: **Programmatic index creation** — `lib/zaq/ingestion/bm25_index_manager.ex`. ETS registry + `CREATE INDEX CONCURRENTLY IF NOT EXISTS` outside transaction. `ensure_index/1` is idempotent.

- [x] Step 13: **Startup self-heal** — `BM25IndexManager.init/0` queries `SELECT DISTINCT language FROM chunks` and ensures all indexes exist. Needs to be wired into supervision tree (see Step 13 note).
  > **Note**: `BM25IndexManager.init/0` is implemented but not yet wired into the supervision tree. Call it from `application.ex` or a startup worker before the ingestion pipeline starts.

- [x] Step 14: **LLM config fields** — `fusion_bm25_weight` and `fusion_vector_weight` added to `LLMConfig` schema, `@llm_read_fields`/`@llm_write_fields` in `System`, and `build_llm_config/1`. Both default to `0.5`.

- [x] Step 15: **`bm25_search_group_by/2`** — Implemented in `DocumentProcessor`. Detects query language, names the partial index, queries with `content <@> to_bm25query(idx, query)`. Returns grouped map matching `similarity_search_group_by/1` shape.

- [x] Step 16: **`rrf_merge/2`** — Pure Elixir. Ranks both legs independently, applies weighted RRF (k=60). Reads `fusion_bm25_weight`/`fusion_vector_weight` from LLM config at call time.

- [x] Step 17: **Update `similarity_search_count/1`** — BM25 FTS leg when `use_bm25: true`; tsvector fallback when `use_bm25: false`.

- [x] Step 18: **Wire into `query_extraction/2`** — `retrieve/1` helper runs both legs via `Task.async` when `use_bm25: true`; vector-only fallback otherwise. `hybrid_search/2` deleted. `build_query_sections/1` updated to use `score_of/1` helper for both `rrf_score` and `vector_distance` maps.

- [x] Step 19: **Config** — `use_bm25?/0` reads `:use_bm25` from `Application.get_env(:zaq, Zaq.Ingestion)`. Defaults `true` in production, set `false` in `config/test.exs` (pg_textsearch not available on PG 16).

- [ ] Step 20: **Post-load merge** — Add a Mix task or Oban worker to run `SELECT bm25_force_merge(index_name)` for each BM25 index after bulk ingestion.

---

### Phase 3 — Validate

- [ ] Step 21: **Validation** — Run full test suite green. Manual smoke test: ingest documents in at least two languages, verify each chunk gets the correct `language` tag, confirm the right partial index is targeted per query, verify startup self-heal on a wiped dev DB, compare retrieval confidence scores before/after.

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Replace GIN index, not add alongside | Avoid dual-maintenance; rollback is a migration step | 2026-04-18 |
| All language indexes created programmatically — no languages hardcoded in migrations | `lingua` detects the actual language per chunk; indexes are created on demand for whatever lands; no deployment needed for new languages | 2026-04-18 |
| Partial indexes per language (`WHERE language = 'xx'`) | Inserts for one language don't touch other language indexes — write overhead stays flat regardless of how many languages are present | 2026-04-18 |
| `simple` fallback index | Languages without a `pg_textsearch` config still get BM25 scoring; no stemming but better than missing the index entirely | 2026-04-18 |
| Language detection at chunk level, not document level | A document can contain multiple languages; per-chunk detection is the only correct granularity | 2026-04-18 |
| Use `lingua` NIF for detection | ~95 language support, no API call, runs in-process during chunking; low-confidence chunks fall back to `simple` | 2026-04-18 |
| Startup self-heal instead of relying on migration trail | Fresh deployments (DB restore, new environment) recreate missing indexes automatically from `chunks.language` data | 2026-04-18 |
| Config flag `use_bm25` before full cut-over | Lets ops toggle without redeploy if issues arise | 2026-04-18 |
| Cross-lingual queries handled by vector leg, not BM25 | BM25 is lexical — a French query finds no English chunks (excluded by partial index predicate). The vector leg is multilingual by nature and carries cross-lingual retrieval. RRF fusion adapts automatically: when BM25 has no signal, vector dominates the score. This is intentional — BM25 adds precision within a language, vector handles cross-lingual recall. | 2026-04-18 |
| Elixir-side RRF fusion via parallel `Task.async`, not SQL-embedded | Two clean independent SQL queries run in parallel; fusion in Elixir is easier to read, test, and maintain than the correlated subquery approach in the old `hybrid_search/2` | 2026-04-18 |
| `bm25_search_group_by/2` mirrors `similarity_search_group_by/1` output shape | `similarity_search_group_by/1` is left completely unchanged; BM25 leg adopts the same grouped map format so `rrf_merge/2` and all downstream pipeline steps need no adaptation | 2026-04-18 |
| `hybrid_search/2` retired as dead code | Replaced entirely by `bm25_search_group_by/2` + `rrf_merge/2` + parallel wiring in `query_extraction/2` | 2026-04-18 |
| Fusion weights stored in LLM config, not module attributes | `fusion_bm25_weight` and `fusion_vector_weight` live alongside `distance_threshold` in `Zaq.System.get_llm_config()` — runtime-tunable via BO system settings with no redeploy needed | 2026-04-18 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Confirm PostgreSQL 17+ on all deployment targets | DevOps | Open |

---

## Definition of Done

- [ ] All 21 steps above completed (Phase 0 clean → Phase 1 red → Phase 2 green → Phase 3 validate)
- [ ] Tests written and passing
- [ ] `mix precommit` passes
- [ ] `docs/services/ingestion.md` updated to reflect BM25 search path
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Plan moved to `docs/exec-plans/completed/`
