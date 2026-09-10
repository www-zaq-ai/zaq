# Database extension provisioning

ZAQ does not install, upgrade or remove PostgreSQL extensions. Before the first
migration, a DBA/provider administrator must provision extensions in **each target
database**, using exactly one script for the chosen engine:

| Engine | Script | Extensions |
| --- | --- | --- |
| PostgreSQL with pgvector | `scripts/setup_postgres_extensions.sql` | `vector` |
| ParadeDB | `scripts/setup_paradedb_extensions.sql` | `vector`, `pg_search` |

Installing server packages or using an image containing extension binaries is
not sufficient: extensions must be enabled in the ZAQ database, not merely in
`postgres` or another maintenance database. The scripts are standalone SQL, safe
to rerun, and transactional. They intentionally do not create roles/databases,
change ownership, relocate extensions, or upgrade existing extensions.

## Provisioning order

1. Have the DBA install compatible server packages: PostgreSQL 16+ and pgvector
   >= 0.7.0 (`halfvec` support); ParadeDB also needs `pg_search` and a callable
   `paradedb.version_info()` function. Managed services may require their own
   extension allowlist or provider-admin procedure.
2. Create the target database and assign it to ZAQ's non-superuser login. Ensure
   this login owns its application schemas and existing application objects.
3. From the repository root, run **one** of the following with a DBA connection
   URL pointing to that database. Use a secret manager or `.pgpass` for credentials;
   never give the DBA connection to the application.

   PostgreSQL:

   ```sh
   psql -X --set ON_ERROR_STOP=1 --dbname "$DB_ADMIN_URL" --file scripts/setup_postgres_extensions.sql
   ```

   ParadeDB:

   ```sh
   psql -X --set ON_ERROR_STOP=1 --dbname "$DB_ADMIN_URL" --file scripts/setup_paradedb_extensions.sql
   ```

4. Configure ZAQ with its non-superuser connection and run migrations/start the
   release. Startup migrations, embedding configuration, and embedding resets
   still perform table/index DDL; a DML-only login is **not** sufficient yet.

The scripts put a newly installed vector extension in `public`. ZAQ's search path
must include `public`. An existing older extension or one installed elsewhere
requires an explicit DBA upgrade/schema reconciliation; rerunning the scripts
does not silently modify it. Capability checks verify that the visible `halfvec`
type belongs to `vector`, rather than trusting only its name or a version string.

## Application role requirements

Use `LOGIN`, `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE`, `NOREPLICATION`, and
`NOBYPASSRLS`. Database ownership supplies database `CONNECT`, `CREATE` and
`TEMPORARY` rights. Ensure `public` is owned by ZAQ or, on PostgreSQL 15+,
`pg_database_owner`. Database ownership alone does not transfer existing table,
sequence, function, type or other object ownership. Reconcile those application
objects explicitly; do not blanket-transfer DBA-owned extension objects.

ZAQ needs schema/type `USAGE` and extension function `EXECUTE` (including the
`paradedb` schema on ParadeDB). These may need explicit grants on hardened
databases. Leave extension ownership with the DBA. ZAQ does not need server-file,
program-execution or cluster-administration privileges. Package-supplied add-on
migrations require separate review against this same policy.

## Migration and runtime behavior

- Missing/incompatible `vector` fails with an error naming both setup scripts,
  telling the operator to choose the correct engine and use the same database.
- Missing `pg_search` is valid for native PostgreSQL. The historical BM25 migration
  emits an explanatory notice and keeps native search rather than failing.
- When an earlier migration has removed `chunks`, BM25 migration work waits for
  runtime table creation. Installed-extension index/permission errors are not
  swallowed. Rollback changes ZAQ indexes only and retains extensions.
- Direct ParadeDB index setup without `pg_search` fails with its script path.
- Historical migration edits affect fresh installations only; existing migration
  versions are not replayed. Existing installations with compatible extensions
  need no extension changes. Installing ParadeDB later does not automatically
  backfill BM25 indexes on existing chunks; schedule explicit index maintenance
  rather than resetting embeddings solely to switch search backends.

## Development, reset and CI

Provision every development, test, E2E and worktree database separately. Run
`mix ecto.create` (or `MIX_ENV=test mix ecto.create`) first if needed, provision
the selected database as DBA, then run `mix setup` / `mix test`. Test database
names include the branch slug, and E2E uses a separate `zaq_test_e2e_<slug>` name.
`mix ecto.reset` drops extensions with the database: instead run `mix ecto.drop`,
`mix ecto.create`, DBA provisioning, then `mix ecto.migrate`.

CI has an explicit administrator provisioning step before migrations, running
the chosen script twice to verify repeatability. Its database name is resolved
from `Zaq.Repo.config()` so branch and E2E suffixes are respected.

The standalone administrative integration check creates and cleans up a unique
database/login, verifies missing prerequisites, runs all migrations under a real
non-superuser login, and exercises chunk creation/reset and BM25 rollback:

```sh
MIX_ENV=test mix run --no-start .github/scripts/extension_installation_test.exs postgres
# On a ParadeDB test server:
MIX_ENV=test mix run --no-start .github/scripts/extension_installation_test.exs paradedb
```

Run this only with a dedicated test-server administrator configuration. It is
deliberately not part of ordinary sandbox tests, which need no role/database
administration. Abruptly terminating it may leave `zaq_ext_test_*` resources for
manual cleanup.
