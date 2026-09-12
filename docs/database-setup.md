# Database and credential bootstrap

ZAQ never installs, upgrades or removes PostgreSQL extensions. Before starting
ZAQ or running migrations, a **superuser DBA** runs one psql entrypoint:

| Engine | Script | Extensions |
| --- | --- | --- |
| PostgreSQL with pgvector | `scripts/setup_postgres_extensions.sql` | `vector` |
| ParadeDB | `scripts/setup_paradedb_extensions.sql` | `vector`, `pg_search` |

Despite their historical names, these scripts now create the database, provision
extensions, create/update the application owner and read-only logins, and set ACLs.
Common logic lives in `setup_database_begin.sql` and `setup_database_finish.sql`,
included with `\ir`. Keep the scripts together and invoke with `psql -X --file`;
do not pipe a single script into stdin. Server packages must already be installed:
PostgreSQL 16+, pgvector >= 0.7.0 (`halfvec`), and optionally ParadeDB with callable
`paradedb.version_info()`. Use a psql client supporting `\getenv` (PostgreSQL 15+).

## Invocation

Connect to an existing **maintenance database**, normally `postgres`, not the
target database. Supply three nonsecret psql variables and two secret environment
variables. Usernames and passwords are intentionally separate: no URI/colon
escaping convention is needed for the new credentials.

```sh
# Inject these through your secret manager, or prompt without echo in Bash:
read -r -s -p 'ZAQ owner password: ' ZAQ_OWNER_PASSWORD; printf '\n'
read -r -s -p 'ZAQ reader password: ' ZAQ_READER_PASSWORD; printf '\n'
export ZAQ_OWNER_PASSWORD ZAQ_READER_PASSWORD

# DBA authentication should use .pgpass / PGPASSFILE or an equivalent secret store.
psql -X --host localhost --username postgres --dbname postgres \
  --set zaq_database=zaq_prod \
  --set zaq_owner=zaq_owner \
  --set zaq_reader=zaq_reader \
  --file scripts/setup_postgres_extensions.sql

# For ParadeDB, replace only the --file value with:
# scripts/setup_paradedb_extensions.sql
unset ZAQ_OWNER_PASSWORD ZAQ_READER_PASSWORD
```

Passwords must be nonempty; use independently generated strong passwords. Names
must be nonempty, at most 63 bytes, and owner/reader/DBA identities must differ.
Reserved `pg_` role names and system/maintenance target databases are rejected.
Identifiers and password literals are SQL-quoted, including embedded quotes and
backslashes. Passwords are stored as SCRAM-SHA-256 verifiers and **both are reset
to the supplied values on every successful pre-migration rerun**.

Do not put passwords in `--set`, connection URLs in argv, shell history, or traced
commands. The scripts disable psql echo and ordinary statement/duration/error
statement logging for their sessions. Environment variables are still accessible
to sufficiently privileged local processes; use a trusted execution host, TLS for
remote connections, and ensure external SQL auditing also redacts credentials.
Configure `pg_hba.conf`/network access separately to require appropriate SCRAM/TLS
authentication: SQL bootstrap cannot configure server packages, network policy,
host authentication, backups, or secret storage.

## Guards, reruns and partial failures

- An absent target is created from `template0` as the executing DBA, then assigned
  to the requested owner after extension provisioning.
- An existing database is accepted only if owned by the **executing DBA** or the
  requested owner. Another superuser's ownership is not sufficient.
- **Any `schema_migrations` relation in a non-temporary schema blocks setup**, even
  an empty ledger left by a failed first migration. Nothing in an existing rejected
  database, including role passwords, is changed. Do not delete a real ledger to
  bypass this protection; request a DBA-managed repair instead.
- Existing roles must have no administrative flags, role memberships (in either
  direction), or dependencies in another database. The reader must own no objects.
  Unsafe/shared roles are rejected rather than silently repurposed. Roles are
  cluster-wide: use separate role names for separate ZAQ databases.
- Role/password changes, extensions, target ownership and ACLs share one transaction.
  `CREATE DATABASE` cannot run inside it: failure can leave a new **DBA-owned empty
  database**, which can be retried. No automatic destructive cleanup is performed.
  Cooperating bootstrap runs serialize inside the target; concurrent first-time
  database creation may fail and need a rerun. Keep ZAQ/migrators stopped throughout.
- Existing extensions must belong to the executing DBA. No extension upgrade,
  relocation, or extension-ownership transfer is performed. Compatible `halfvec`
  must belong to vector in `public`; an identically named domain is insufficient.

After successful bootstrap, configure ZAQ with the **owner** credentials and run
migrations. Database ownership supplies the DDL rights ZAQ needs for migrations and
runtime chunk creation/reset. `public` follows the database owner using
`pg_database_owner`; existing application-object ownership is not transferred.
An existing database containing objects owned by another role needs explicit DBA
reconciliation. Never transfer DBA-owned extension objects to ZAQ.

## Read-only access

The reader receives CONNECT, schema USAGE, table/view SELECT and sequence SELECT
across all non-system schemas. Owner- and executing-DBA-created future schemas,
tables and sequences receive matching default privileges, including recreated
chunks. Other object-creating roles require equivalent DBA-managed defaults.

The reader has no schema/database CREATE, TEMPORARY, table writes, sequence
USAGE/UPDATE, role memberships or administrative flags. Existing PUBLIC/reader
write grants (including column grants) and permissive defaults are removed.
PUBLIC/reader routine execution is revoked in application/extension schemas;
the owner retains execution on existing routines. Future owner-created routines
are not executable by PUBLIC. This avoids exposing write-capable SECURITY DEFINER
functions through a nominally read-only account. Add-ons requiring callable reader
functions must receive a separate security review and explicit grants.

**This is broad database read access, not ZAQ application authorization.** It
includes authentication/configuration tables and encrypted secret values. Protect
these credentials accordingly; RLS is not bypassed. PostgreSQL system-schema
defaults remain untouched. Subsequent privileged grants, migrations that override
ACLs, or dangerous views/routines require DBA review; the script is not a sandbox
against future privileged schema changes. It does not revoke PUBLIC CONNECT on
other databases in the cluster.

## Existing deployments and development/CI

Already-migrated databases must use explicit DBA maintenance for extension repair,
password rotation or ACL changes; bootstrap intentionally refuses them. Installing
ParadeDB later does not backfill BM25 indexes. Existing compatible deployments need
no extension changes. Historical migrations validate prerequisites; BM25 retains
native fallback when `pg_search` is absent and rollback preserves extensions.

Bootstrap every dev/test/E2E/worktree database separately **before any migration**.
Resolve the exact database through `Zaq.Repo.config()` (branch, E2E and partition
suffixes apply). Do not run `mix ecto.create` first; bootstrap creates the DB.
After an intentional database reset, bootstrap again before migration; ZAQ's
restricted owner cannot recreate a dropped database itself.

CI's `.github/scripts/provision-test-database.exs` resolves that name and bootstraps
twice using generated, database-specific restricted owner/reader credentials.
The normal suite still uses its existing administrator configuration; the separate
integration suite verifies the actual restricted login path:

```sh
MIX_ENV=test mix run --no-start .github/scripts/extension_installation_test.exs postgres
MIX_ENV=test mix run --no-start .github/scripts/extension_installation_test.exs paradedb
```

Run only against dedicated test servers with administrator credentials. The suite
connects to `postgres`, creates isolated databases/logins, validates guards,
password rotation, ACLs, migrations/runtime/rollback, and cleans up. Abrupt
termination can leave `zaq_ext_test_*` resources requiring manual cleanup.
