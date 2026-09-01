# Execution Plan: ParadeDB FTS Backend Self-Heal

**Date:** 2026-06-22
**Author:** agent
**Status:** `active`
**Related debt:** none
**PR(s):** TBD
**Source issue:** `docs/exec-plans/issues/paraddb.md`

---

## Goal

On a ParadeDB server where the ZAQ database was created separately from the
image's default `paradedb` database, `pg_search` is *available* (binary loaded
via `shared_preload_libraries`) but never *created* in the ZAQ DB. Detection
therefore falls back to **Native** permanently, and downstream actions that
assume a ParadeDB-consistent state (e.g. `pg_dump`) crash with
`pg_search must be loaded via shared_preload_libraries`.

Done means: a ParadeDB deployment pointed at a custom database **automatically
converges to the ParadeDB backend at startup** — the extension is created in
the connected DB, the BM25 index is provisioned when a `chunks` table exists,
and `[FTSBackend] active backend: ...ParadeDB` is logged. Plain PostgreSQL
servers (no `pg_search` available) are unaffected and stay on Native. No
detection probe ever raises, including inside an open transaction.

---

## Context

Docs read before writing this plan:
- [x] `docs/architecture.md` — layering, no direct cross-service calls
- [x] `docs/services/ingestion.md` — FTS backend ownership
- [x] `docs/conventions.md` — module responsibility / naming
- [x] `docs/exec-plans/PLAN_STRATEGY.md` / `PLAN_TEMPLATE.md`

Existing code reviewed:
- `lib/zaq/ingestion/fts_backend.ex` — behaviour + `detect_and_cache/0`,
  `setup_index/2`, `paradedb_functional?/0`, transaction-safe probes
- `lib/zaq/ingestion/fts_backend/parade_db.ex` — `setup_bm25_index/2`
  (CREATE EXTENSION + CREATE bm25 index)
- `lib/zaq/ingestion/fts_backend/native.ex` — `setup_bm25_index/2`
  (content_tsv column + GIN index)
- `lib/zaq/application.ex:54` — `FTSBackend.detect_and_cache()` at startup
- `priv/repo/migrations/20260418000001_add_pg_textsearch_bm25_simple_index.exs`
  — `DO/EXCEPTION WHEN OTHERS` block that silently skips and never retries
- `test/zaq/ingestion/fts_backend_test.exs` — existing detection tests

### Infrastructure Audit

- [x] Existing entry points checked: `ParadeDB.setup_bm25_index/2` already
  runs `CREATE EXTENSION IF NOT EXISTS pg_search` + creates `chunks_bm25_idx`
  idempotently. The self-heal must **reuse** it, not duplicate the SQL.
  `FTSBackend` already centralises transaction-safe probing helpers
  (`rows_present?/1`, savepoint pattern) — reuse those.
- [x] `@moduledoc` read for `FTSBackend` — it is the "runtime detector for
  pluggable full-text search backends". A self-heal that converges the
  connected DB to a working backend before caching fits this responsibility.
- [x] No parallel code path: heal lives in `FTSBackend`, delegates index/
  extension DDL to `ParadeDB.setup_bm25_index/2`. No new SQL home created.
- [x] Provider/credential/URL logic: n/a (FTS, not LLM).

---

## Approach

Add a **transaction-guarded self-heal** at the top of
`FTSBackend.detect_and_cache/0`:

1. **Distinguish "ParadeDB image, extension not created" from "plain Postgres".**
   Probe `pg_available_extensions WHERE name = 'pg_search' AND
   installed_version IS NULL`. A non-null/absent row means either already
   installed (nothing to heal) or unavailable (plain PG — never attempt
   `CREATE EXTENSION`). Only the "available + not installed" case heals.

2. **Run DDL savepoint-protected, not gated on transaction state.**
   ~~Guard with `not Repo.in_transaction?()`.~~ **Corrected (2026-06-22):**
   the red test runs inside the sandbox transaction yet must converge to
   ParadeDB, so an `in_transaction?` gate would make the heal untestable and
   skip it whenever detection runs inside an enclosing transaction. Instead
   wrap the heal DDL in `mode: :savepoint` (the same pattern
   `version_info_callable?/0` already uses): a failure rolls back to the
   savepoint without aborting the enclosing transaction, preserving the
   "probes never abort an enclosing transaction" invariant. In production the
   DDL effectively runs once — after the startup heal installs the extension,
   the `available + uninstalled` probe returns false and later detections skip
   it.

3. **Heal, fully guarded.** Run `ParadeDB.setup_bm25_index/2` (CREATE EXTENSION
   + CREATE bm25 index when `chunks` exists). Wrap so a server whose binary is
   not actually preloaded fails soft and falls through to Native. The native
   `content_tsv` column/GIN index is provisioned too (universal fallback,
   matches `setup_index/2` semantics) when `chunks` exists.

4. **Fall through to existing detection** → `paradedb_functional?/0` now
   succeeds → cache + log ParadeDB.

Why this over the alternatives in the issue:
- *Migration idempotent-retry alone* cannot heal an **already-applied** migration
  (the `schema_migrations` row exists; `ecto.migrate` is a no-op). It fixes only
  future fresh installs.
- *Gating migrations on ParadeDB readiness* adds deploy-time coupling and still
  does not heal databases already in the broken state.
- The self-heal fixes **already-broken running deployments** (the reported,
  priority-bumped case) and is idempotent on every boot.

---

## Steps

- [x] Step 1: Add `pg_search`-available-but-uninstalled probe to `FTSBackend`
  - Module placement check: `Zaq.Ingestion.FTSBackend` — detector module,
    `@moduledoc` covers runtime backend detection. Probe sits beside the
    existing `version_info_in_catalog?/0` family.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test: returns `true` when `pg_search` is available and
      not installed; `false` when installed; `false` when unavailable (plain PG)
    - [ ] Branch/path coverage: all three `pg_available_extensions` outcomes
      via `rows_present?/1`
    - [ ] Edge external API mocks only: none (real Repo)
  - Coverage target: `>= 95%`

- [x] Step 2: Add savepoint-protected `self_heal/0` (startup-only, `:ingestion`-role-gated in `Zaq.Application`); detection stays pure
  - Module placement check: `Zaq.Ingestion.FTSBackend`. Delegates DDL to
    `FTSBackend.ParadeDB.setup_bm25_index/2` (no duplicate SQL).
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test: on a ParadeDB test DB with extension dropped from
      the ZAQ DB, `detect_and_cache/0` recreates it and caches `ParadeDB`
    - [ ] Branch/path coverage: (a) in-transaction → DDL skipped, detection
      unchanged; (b) not available → no DDL, Native; (c) available+uninstalled
      + not in tx → heal → ParadeDB; (d) heal raises internally → soft fail →
      Native (guarded)
    - [ ] Idempotency: second `detect_and_cache/0` is a no-op (extension already
      installed branch)
    - [ ] Edge external API mocks only: none
  - Coverage target: `>= 95%`
  - Note: gate the ParadeDB-DB-only tests so they are skipped on plain-PG CI
    (follow whatever tag `fts_backend_test.exs` already uses for ParadeDB cases).

- [x] Step 3: Make migration `20260418000001` self-documenting about the heal
  - Module placement check: migration file. Add a comment that the
    `DO/EXCEPTION` skip is intentionally healed at runtime by
    `FTSBackend.detect_and_cache/0` so the silent-skip is no longer a dead end.
    (No behavioural migration change — the runtime heal is the fix.)
  - Temporary code? no
  - Tests to add: none (comment only)
  - Coverage target: n/a

- [x] Step 4: Docs + verification
  - [x] `docs/services/ingestion.md` documents the startup self-heal + custom-DB scenario.
  - [x] `mix format` + `mix q` pass (format, compile --warnings-as-errors, docs, credo --strict).
  - [ ] Open PR; move plan to `completed/` and add resolution note to the issue.

---

## Decisions Log

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Self-heal over migration-retry | Heals already-applied/already-broken deployments, not just fresh installs | 2026-06-22 |
| ~~Gate DDL on `not Repo.in_transaction?()`~~ → savepoint-protect instead | The red test runs in the sandbox transaction yet must converge to ParadeDB; an `in_transaction?` gate makes the heal untestable and skips it mid-transaction. Savepoint mode keeps it safe without gating. | 2026-06-22 |
| **Heal is startup-only + role-gated, detection stays pure** | DDL must not run on the lazy `impl/0`/request hot path (a BM25 index build on a populated table is heavy). `detect_and_cache/0`/`impl/0` are read-only; `FTSBackend.self_heal/0` runs the DDL once at startup, gated in `Zaq.Application` to the `:ingestion` role so multi-node boots don't race on `CREATE EXTENSION`/`CREATE INDEX`. | 2026-06-22 |
| Extract `ParadeDB.bm25_index_ddl/0` | Single source of truth for the BM25 index DDL; reused by `setup_bm25_index/2` and the heal | 2026-06-22 |
| Public `heal_extension_result/3` | The DDL failure branch can't be triggered against a live ParadeDB; expose the handler for direct unit testing (same pattern as `callable_probe_result/1`) | 2026-06-22 |
| **Broaden self-heal to handle `:stale` + warn on degraded** | v0.24.0 repro showed the "extension not created" case doesn't occur there (template1 inheritance); the real old-client failure is an extension **older than the loaded library** after an image upgrade (`version_info()` + `pg_dump` break). Added `ALTER EXTENSION … UPDATE` for `:stale`, and a loud `warn_if_degraded/2` for the unfixable not-loaded-library case (server config + restart). Pure `pg_search_state_from/1` + `heal_command/1` keep the `:stale` path unit-testable without staging a stale extension. | 2026-06-22 |
| BO health indicator deferred to follow-up | "(a)" ships the auto-fix now; surfacing degraded state in the BO tracked in `docs/exec-plans/issues/fts-degraded-health-indicator.md` | 2026-06-22 |
| **Migration is the primary fix; self-heal is a safety net** | Client correctly flagged that app-boot self-heal does not heal the separate **test** database, and that CI passing proved nothing (CI uses standard PG where the path is skipped). Added migration `20260622000000_ensure_pg_search_current` (guarded `CREATE EXTENSION` + `ALTER EXTENSION … UPDATE`) that runs in every environment's migration flow, deterministically healing dev/test/CI/prod. Proved on `paradedb/paradedb:v0.24.0-pg18`: after dropping pg_search from `zaq_test`, `mix ecto.migrate` alone restores it (extension + `version_info()`) and tests `:98`/`:110` pass — no app boot involved. | 2026-06-22 |

---

## Blockers

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| Need a ParadeDB-capable test DB in CI to exercise heal path | devops | open — may tag tests to skip when `pg_search` unavailable |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing (heal, idempotency, transaction-skip, plain-PG no-op, soft-fail)
- [ ] Integration tests cover key branches/paths
- [ ] Any mocks limited to edge external API calls (none here)
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix precommit` / `mix q` passes
- [ ] `docs/services/ingestion.md` updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] `docs/exec-plans/issues/paraddb.md` resolved
- [ ] Plan moved to `docs/exec-plans/completed/`
