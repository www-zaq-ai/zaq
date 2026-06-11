# PR #450 Review Plan

**Branch:** fix/paradedb
**PR title:** feat(ingestion): add pluggable fts backend with native postgres default
**Reviewers:** jfayad
**Generated:** 2026-06-11

---

## Summary

| Category | Count |
|---|---|
| Bug / Correctness | 1 |
| Tests | 2 |
| Code Quality | 2 |
| Documentation | 1 |

**Total actionable comments:** 6 (excludes nits)
**Reconciliation:** fetched 1 review + 4 inline threads + 1 general comment = 6; 5 comments categorized (review body split into 2 findings → 6 plan entries) + 1 excluded = 6 ✓

---

## Excluded

| Author | Location | Reason excluded |
|---|---|---|
| @jat10 | — (general comment 4671730330) | Review-agent invocation prompt (instructions for an automated reviewer), not reviewer feedback on the code |

---

## Category: Bug / Correctness

### Comment 1 — `lib/zaq/ingestion/fts_backend.ex` line 38
**Reviewer:** @jfayad
**Raw comment:**
> wrong condition to check, it should be specifically targeting the existence of paradedb functions

**What to fix:**
`detect_and_cache/0` currently probes `pg_extension WHERE extname = 'pg_search'`. An extension catalog entry does not guarantee the ParadeDB functions are actually callable (e.g. extension row present but functions missing/broken, or schema not available). Detection must probe for the actual ParadeDB functions the backend calls.

**Implementation note:**
In `Zaq.Ingestion.FTSBackend.detect_and_cache/0`, replace the `pg_extension` query with the **vendor-sanctioned functional probe**. ParadeDB's own upgrade docs state that `pg_extension` is only "what Postgres' catalog thinks" and that `paradedb.version_info()` is the authoritative check of what is actually installed and loaded — the two can legitimately disagree (e.g. SQL upgrade scripts not applied, or extension binary not reloaded). This mirrors the industry pattern (PostGIS's canonical check is `SELECT PostGIS_version()`, not a catalog query): call a function the extension itself provides and let successful execution prove the binary works.

Detection query:

```sql
SELECT 1 FROM paradedb.version_info()
```

- `{:ok, _}` → the pg_search binary is loaded and callable → additionally verify the legacy BM25 index exists (`SELECT 1 FROM pg_indexes WHERE indexname = 'chunks_bm25_idx'`), since the ParadeDB backend's `@@@` queries error without it → both pass → `FTSBackend.ParadeDB`.
- Any error or missing index → existing `{:error, _} -> Native` fallback.

Why not a canary `@@@` query against `chunks` as the probe: it has a bootstrapping hazard — `@@@` errors when the BM25 index doesn't exist yet, so a fresh ParadeDB install would permanently detect as Native before `setup_bm25_index/2` ever runs. The `version_info()` + `pg_indexes` pair avoids that while still being execution-proof against forked/patched images: a fake catalog row can't fake a successful `paradedb.version_info()` call. Optionally log the returned version and gate on a minimum supported version.

---

## Category: Tests

### Comment 2 — top-level review (id 4470420901), finding 1 of 2
**Reviewer:** @jfayad
**Raw comment:**
> Make sure to add a CI step that runs under a paradeDB for the test that activates the branch of using fts

**What to fix:**
`.github/workflows/elixir-ci.yml` currently has a single `test` job whose service container is `paradedb/paradedb:0.23.0` — the whole suite runs under ParadeDB and the native Postgres path (the PR's new *default*) is never tested in CI. Restructure into **two test phases**:

1. **`test` (main phase)** — service image switched to native Postgres (`pgvector/pgvector:pg18`, aligning with Comment 5). Runs the full suite with `:paradedb`-tagged tests excluded. Keeps the existing Coveralls step (`mix coveralls.github`) and the fork-PR `mix test` step.
2. **`test-paradedb` (second phase)** — service image `paradedb/paradedb:0.23.0` (same env/ports/healthcheck as the main job). Runs **only** the ParadeDB tests: `mix test --only paradedb`. No coverage upload needed; a plain `mix test --only paradedb` step covering both internal and fork PRs is enough.

**Implementation note:**
- Duplicate the existing `test` job as `test-paradedb`, change the main job's `services.postgres.image` to `pgvector/pgvector:pg18`, keep `paradedb/paradedb:0.23.0` in the new job.
- Tag ParadeDB-specific tests with `@moduletag :paradedb` (or `@tag :paradedb` per test) and add `:paradedb` to the default excludes in `test/test_helper.exs` — currently `ExUnit.start(exclude: [:integration], capture_log: true)` → `exclude: [:integration, :paradedb]`. This keeps local runs on native Postgres green; the `test-paradedb` job opts back in via `--only paradedb` (which also implies `--include`).
- The paradedb phase exercises: `FTSBackend.detect_and_cache/0` returning `FTSBackend.ParadeDB` (the `impl/0` assertion from Comment 3) plus the ParadeDB search branch (`bm25_search_group_by`, index setup).
- Tests must call `FTSBackend.reset_cache/0` in setup/on_exit since the backend is cached in `:persistent_term`.
- Note: if `mix coveralls.github` enforces a minimum coverage threshold, verify excluding the paradedb tests from the main phase doesn't drop coverage of `fts_backend.ex` below it — the native-path tests from Comment 3 should cover the shared code.

### Comment 3 — top-level review (id 4470420901), finding 2 of 2
**Reviewer:** @jfayad
**Raw comment:**
> + one specific test to confirm the impl/0 is returning the correct backend

**What to fix:**
There is no test file for `Zaq.Ingestion.FTSBackend` (nothing matching `fts` under `test/zaq/ingestion/`). Add a dedicated test asserting `FTSBackend.impl/0` returns `FTSBackend.Native` on plain Postgres and `FTSBackend.ParadeDB` when ParadeDB functions exist.

**Implementation note:**
Create `test/zaq/ingestion/fts_backend_test.exs`: native assertion runs everywhere; ParadeDB assertion is `@tag :paradedb` and runs in the CI job from Comment 2. Also cover the caching behavior (`detect_and_cache/0` + `reset_cache/0`) and the error-fallback-to-Native branch.

---

## Category: Code Quality

### Comment 4 — `priv/repo/migrations/20260528000001_replace_paradedb_with_native_fts.exs` line 1
**Reviewer:** @jfayad
**Raw comment:**
> rename the migration file to align with what it does

**What to fix:**
The filename says "replace_paradedb_with_native_fts" but the migration (module `AddNativeFtsColumn`) only *adds* the native FTS column/GIN index alongside the existing ParadeDB index — it explicitly does not drop anything. Rename the file to match the module/behavior.

**Implementation note:**
`git mv` to `priv/repo/migrations/20260528000001_add_native_fts_column.exs` (keep the same timestamp so already-migrated databases are unaffected; only the module name matters to Ecto and it already matches).

### Comment 5 — `docker-compose.yml` line 3
**Reviewer:** @jfayad
**Raw comment:**
> pg18

**What to fix:**
Bump the Postgres image from `pgvector/pgvector:pg17` to the pg18 variant.

**Implementation note:**
Change `image: pgvector/pgvector:pg17` → `image: pgvector/pgvector:pg18` in `docker-compose.yml`. Use the same `pgvector/pgvector:pg18` image for the main `test` job in `.github/workflows/elixir-ci.yml` (see Comment 2) and check `e2e.yml` for a Postgres pin to align. Note: a local volume created under pg17 won't start under pg18 without a dump/restore — call this out in the PR description for devs with existing `pgdata` volumes.

---

## Category: Documentation

### Comment 6 — `lib/zaq/ingestion/fts_backend.ex` line 27
**Reviewer:** @jfayad
**Raw comment:**
> let's document when to use persistent_term (read efficient) vs ETS (update performance) for caching

**What to fix:**
Document the rationale for choosing `:persistent_term` here: reads are constant-time with no copying, ideal for write-once values like the detected backend, whereas ETS is preferable for values updated frequently (persistent_term updates trigger a global GC pass).

**Implementation note:**
Extend the `@moduledoc` of `Zaq.Ingestion.FTSBackend` (or a comment above `@cache_key`) with the persistent_term-vs-ETS trade-off: persistent_term = read-optimized, near-zero-cost lookups, expensive updates (global GC); ETS = cheap concurrent updates, slightly costlier reads. The backend is detected once at startup and effectively never changes → persistent_term is the right fit.

---

## Implementation Order

1. **[bug]** Comment 1 — fix the ParadeDB detection condition in `FTSBackend.detect_and_cache/0`. Blocks correctness; the tests in steps 2–3 must assert against the *correct* probe.
2. **[tests]** Comment 3 — add `fts_backend_test.exs` verifying `impl/0` returns the right backend (native + tagged ParadeDB cases).
3. **[tests]** Comment 2 — split CI into two test phases: main `test` job on native Postgres (`pgvector/pgvector:pg18`, full suite, paradedb-tagged tests excluded) + `test-paradedb` job on `paradedb/paradedb:0.23.0` running `mix test --only paradedb`. This proves the detection fix under both backends.
4. **[quality]** Comment 4 — rename the migration file to `add_native_fts_column.exs` (standalone, zero risk).
5. **[quality]** Comment 5 — bump docker-compose (and any CI pins) to pg18; verify the ParadeDB CI image choice from step 3 is consistent.
6. **[docs]** Comment 6 — document the persistent_term vs ETS caching rationale in the moduledoc.

---

## Definition of Done

- [ ] Every `bug` comment addressed (detection probes actual ParadeDB functions)
- [ ] Every `tests` comment addressed (impl/0 test + ParadeDB CI step, both green)
- [ ] Every `quality` comment addressed (migration renamed, pg18 image)
- [ ] Every `docs` comment addressed (persistent_term vs ETS rationale documented)
- [ ] `mix q` passes
- [ ] PR updated and re-requested review
