## Summary

Surface the FTS (full-text search) backend health in the admin/BO UI so an
operator can see when search is running in **degraded (Native)** mode and what
to do about it — instead of the signal living only in startup logs.

This is the follow-up "(b)" to the pg_search self-heal work. The self-heal
(`Zaq.Ingestion.FTSBackend.self_heal/0`) already auto-fixes the cases ZAQ can
fix at startup:

- `:uninstalled` → `CREATE EXTENSION pg_search`
- `:stale` (extension older than the loaded library, e.g. after an image
  upgrade) → `ALTER EXTENSION pg_search UPDATE`

…and logs a loud warning when it ends up on Native while pg_search is installed
(the library is not loaded via `shared_preload_libraries` — a server config +
restart ZAQ cannot perform). See `docs/services/ingestion.md` and
`docs/exec-plans/issues/paraddb.md`.

## Problem

The degraded-mode warning is currently only a `Logger.warning` at startup. A
non-technical operator running an on-prem deployment will not see it, so they
can be silently stuck on the slow backend.

## Proposed work

- Add a system-health indicator in the BO that shows the active FTS backend
  (`ParadeDB` vs `Native`) and, when degraded, the reason + remediation text
  (the same message `warn_if_degraded/2` already produces).
- Reuse the existing status-indicator pattern introduced for channel/listener
  status (see commit "surface errors if any to feed listener status
  indication") rather than building a new surface.
- All BO ↔ ingestion reads go through `NodeRouter.dispatch/1` with a
  `%Zaq.Event{}` — do not call `FTSBackend` directly from `lib/zaq_web/`.
- Source of truth: `FTSBackend.impl/0` for the active backend;
  `warn_if_degraded/2` inputs (active backend + `pg_search` installed?) for the
  degraded reason.

## Out of scope

- The auto-heal itself (done in "(a)").
- Auto-`REINDEX` after a major pg_search upgrade (separate consideration).

## Notes

- Detection (`detect_and_cache/0`/`impl/0`) must stay read-only; the indicator
  reads cached state, it does not probe or run DDL.
