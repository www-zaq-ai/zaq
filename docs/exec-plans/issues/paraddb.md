## Summary

On a ParadeDB server, ZAQ still selects the **Native** FTS backend if the
ZAQ database was created separately from the image's default `paradedb`
database. The server is ParadeDB, but `pg_search` is never created **in the
ZAQ database**, so detection correctly falls back to Native.

## Root cause

PostgreSQL extensions are **per-database**, not per-server:

- `shared_preload_libraries = pg_search` loads the binary at the instance
  level (makes it *available*).
- `CREATE EXTENSION pg_search` creates the SQL objects (`paradedb` schema,
  `paradedb.version_info()`, BM25 access method) **inside one database**.

The ParadeDB image only pre-creates the extension in its default `paradedb`
database. A separately-created ZAQ database has `pg_search` *available* but
*not created*, so `FTSBackend` probes `paradedb.version_info()`, finds it
absent, and uses Native.

Migration `20260418000001_add_pg_textsearch_bm25_simple_index.exs` does run
`CREATE EXTENSION IF NOT EXISTS pg_search`, but it is wrapped in a
`DO/EXCEPTION` block that **silently skips** if `pg_search` is not loadable at
migration time (e.g. migrations ran before ParadeDB was ready). Once skipped,
the migration is marked applied and **never retries** — so `mix ecto.migrate`
does not fix it.

## Reproduction

1. Run the ParadeDB image but point ZAQ at a custom database (not `paradedb`).
2. Run migrations (or run them before ParadeDB is fully ready).
3. Observe at startup: `[FTSBackend] active backend: ...Native`.
4. In the ZAQ DB: `pg_search` not in `pg_extension`, no `chunks_bm25_idx`.

## Proposed fix

Add a startup self-heal: when `pg_search` is **available but not yet created**
in the connected DB, run `CREATE EXTENSION pg_search` + `setup_index/2` before
caching the backend, so custom-database installs converge to ParadeDB
automatically. Alternatively, make the index migration idempotently retry, or
gate migrations on ParadeDB readiness.


## Comment
I want to bump up the priority of this task.

On a ParadeDB that is being detected as Native Pg, I have the following error that is crashing multiple actions.

> pg_dump: error: query failed: ERROR:  pg_search must be loaded via shared_preload_libraries. Add 'pg_search' to sha
red_preload_libraries in postgresql.conf and restart Postgres.