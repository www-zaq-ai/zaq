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

### Docker image and automatic Compose bootstrap

The image has two startup modes. Default `server` runs the existing release
migrations and then execs ZAQ. `provision-db` runs psql only and exits; it never
loads ZAQ or runs migrations. Two small shell scripts dispatch startup and invoke
psql; database logic remains in the canonical SQL scripts and their relative includes.

For explicit DBA use, pass `provision-db --database NAME --owner LOGIN --reader LOGIN`
as the container command. Supply `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` (the
maintenance database), DBA authentication through `PGPASSFILE` or `PGPASSWORD`,
and the two `ZAQ_*_PASSWORD` environment variables described above. Alternatively,
names can come from `ZAQ_DATABASE`, `ZAQ_OWNER`, `ZAQ_READER`. These names and both
passwords are required by the wrapper. No credentials belong in argv.

`--engine auto` (default) probes **available** server extensions in the maintenance
database: available `pg_search` selects ParadeDB, otherwise PostgreSQL. Probe errors
fail, rather than falling back. `--engine postgres` or `--engine paradedb` overrides
selection; canonical SQL still validates actual capabilities. Connect with TLS and
appropriate libpq environment settings for remote DBA work. The supplied Compose
configuration provisions its bundled local DB.

`docker-compose.yml` starts the maintenance DB, then the **same ZAQ image** with
`provision-db --automatic`. ZAQ depends on that job completing successfully.
Use Docker Compose v2 with `service_completed_successfully` support.

Supply these environment variables before running Compose:

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Existing application-owner connection URL; passed unchanged to ZAQ |
| `ZAQ_OWNER_PASSWORD` | The same owner password, unencoded, for the DBA scripts |
| `ZAQ_READER_PASSWORD` | Independently supplied read-only login password |
| `ZAQ_DATABASE` | Target DB; Compose defaults to `zaq_prod` |
| `ZAQ_OWNER` | Application owner; Compose defaults to `zaq_owner` |
| `ZAQ_READER` | Reader login; Compose defaults to `zaq_reader` |
| `POSTGRES_PASSWORD` | Bundled DBA password, used only by PostgreSQL and the provisioning service |

For the bundled Compose network, `DATABASE_URL` must point to host `postgres`, port
5432, and the selected database/owner. URI-encode its credentials; the separate
password variables must contain the raw values. Use your existing environment or
secret manager. **No credentials are generated, written to files, or embedded in
the image.** Only `DATABASE_URL` is passed to ZAQ; DBA and reader credentials remain
in the provisioning service. Avoid logging rendered Compose configuration, which
contains the supplied secrets.

On first run, automatic mode invokes the selected canonical DBA script and records
a DBA-owned `zaq_bootstrap.receipt` in the **same transaction** as credentials,
extensions and ACLs. The receipt contains only nonsecret database/owner/reader/engine
identity and a version, not passwords or a locally persisted token.

On subsequent starts, a trusted matching receipt selects validation only: check
database ownership, restricted role flags/memberships, extension capabilities and
supplied owner/reader authentication. `DATABASE_URL` must authenticate as that owner
against the same server address/port and database OID. An incorrect URL blocks ZAQ,
but bootstrap may already have committed against the configured DBA target. The
wrapper does not parse the URL to choose a different provisioning target.

Restart never rotates passwords or infers success from `schema_migrations`. A crash
after commit is safe because the receipt is already present. A transaction failure
can be retried with the same environment. Concurrent first-time runs may race and
one may fail; retry after the other finishes. Keep other migrators stopped.

Changing environment passwords is **not** a rotation mechanism: validation fails
until a DBA reconciles the database credentials. A missing/untrusted/mismatched
receipt on a migrated database requires DBA maintenance; do not delete migration
ledgers to bypass this. Compatible legacy databases without a receipt are not
automatically adopted after migrations. A pristine database still follows the
canonical bootstrap guards.

Retain/back up `pgdata` and retain your externally managed credential configuration.
If the database is intentionally dropped, it has no receipt and is bootstrapped
again before migration. No external marker tracks deleted databases. For external
databases, use explicit provisioning with their DBA connection and a separately
configured app-only service, rather than the bundled local provisioning job.

The bundled DBA password retains the previous local-only `postgres` default;
`POSTGRES_PASSWORD` overrides it for **new clusters**. Changing that environment
variable does not rotate the password in an existing PostgreSQL volume. Harden
network exposure/authentication and use separately managed secrets for production.

`zaq-local.sh` and its live Gist remain unchanged. There is no separate installer
Compose artifact. Updating the Gist is a separate rollout step after publishing a
compatible image. Users must supply the database environment above; the installer
does not generate it. Before rollout, verify fresh `up`, `down`/`up`, failed-job
gating and application migrations with a Docker-capable runner. The administrative
integration suite below also tests the shell entrypoint and automatic restart path
against both database engines; no Python test dependencies are required.

### Kubernetes init container

Use the same ZAQ image as an ordinary, terminating init container with
`args: ["provision-db", "--automatic", ...]`. Leave the image entrypoint intact.
Kubernetes waits for this init container to complete successfully before starting
ZAQ; the application container retains its default migrations-then-server startup.

**The init container is stateless and needs no volume or PVC.** The receipt is the
`zaq_bootstrap.receipt` table **inside PostgreSQL**, committed atomically with the
DBA setup. It confirms that the complete bootstrap transaction succeeded. It is
not a file in the image or init container. Credentials come from Secret-backed
environment variables; database persistence belongs to your database deployment.

#### Example Deployment

This minimal example assumes an existing PostgreSQL service and three Secrets in
the Deployment's namespace. Create the Secrets through your normal secret-management
process, not by committing credentials to manifests:

| Secret | Keys | Used by |
| --- | --- | --- |
| `zaq-db-owner` | `database-url`, `password` | Init container: both; ZAQ: URL only |
| `zaq-db-bootstrap` | `dba-user`, `dba-password`, `reader-password` | Init container only |
| `zaq-runtime` | `secret-key-base`, `encryption-key` | ZAQ only |

`database-url` must contain the application-owner credentials and target
`postgresql.database.svc.cluster.local:5432/zaq_prod`. Its username must be
`zaq_owner` in this example. URI-encode the URL's password; the `password` key must
contain the same password **unencoded**. `dba-user` must satisfy the canonical
scripts' superuser requirement. Managed providers that cannot grant these rights
need DBA/provider-managed provisioning instead.

Replace both image placeholders with the **same released image containing the
provisioning entrypoint**; pin an immutable digest for production. Adjust the
database endpoint, names, application host and runtime settings for your environment.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zaq
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: zaq
  template:
    metadata:
      labels:
        app: zaq
    spec:
      automountServiceAccountToken: false
      initContainers:
        - name: provision-db
          image: ghcr.io/www-zaq-ai/zaq:REPLACE_WITH_RELEASE_TAG
          args:
            - provision-db
            - --automatic
            - --engine
            - auto
            - --database
            - zaq_prod
            - --owner
            - zaq_owner
            - --reader
            - zaq_reader
          env:
            - name: PGHOST
              value: postgresql.database.svc.cluster.local
            - name: PGPORT
              value: "5432"
            - name: PGDATABASE
              value: postgres
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: zaq-db-bootstrap
                  key: dba-user
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: zaq-db-bootstrap
                  key: dba-password
            - name: ZAQ_OWNER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: zaq-db-owner
                  key: password
            - name: ZAQ_READER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: zaq-db-bootstrap
                  key: reader-password
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: zaq-db-owner
                  key: database-url
      containers:
        - name: zaq
          image: ghcr.io/www-zaq-ai/zaq:REPLACE_WITH_RELEASE_TAG
          ports:
            - name: http
              containerPort: 4000
          env:
            - name: PHX_SERVER
              value: "true"
            - name: PORT
              value: "4000"
            - name: PHX_HOST
              value: zaq.example.com
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: zaq-db-owner
                  key: database-url
            - name: SECRET_KEY_BASE
              valueFrom:
                secretKeyRef:
                  name: zaq-runtime
                  key: secret-key-base
            - name: SYSTEM_CONFIG_ENCRYPTION_KEY
              valueFrom:
                secretKeyRef:
                  name: zaq-runtime
                  key: encryption-key
```

`PGDATABASE=postgres` selects the existing **maintenance database** for the DBA
connection. `--database zaq_prod` names the database to create/provision; they are
not interchangeable. Instead of the three name flags, you can set `ZAQ_DATABASE`,
`ZAQ_OWNER`, and `ZAQ_READER` on the init container. Name flags override those
environment variables. Keep all passwords out of `args`.

`--engine auto` probes available extensions; use `postgres` or `paradedb` when you
want an explicit backend choice. Always retain `--automatic` for this per-Pod
pattern: without it, the strict DBA bootstrap runs again and refuses a migrated DB.

#### Exit codes and restarts

- **Exit 0:** bootstrap or receipt-based validation succeeded. Kubernetes can start
  the application containers after all ordinary init containers have completed.
- **Nonzero exit:** invalid inputs, connection/SQL failures or failed validation.
  The shell stops on failure and psql uses `ON_ERROR_STOP=1`. In a Deployment,
  Kubernetes retries the failed init container with backoff; ZAQ remains blocked.
  The scripts impose no retry-count limit. Missing Secrets can prevent the init
  container from starting at all until the configuration is fixed.
- **Replacement/new Pod:** the init container runs again. A trusted receipt selects
  validation only, including supplied credentials; it does not rotate passwords.
- **Application-container restart in the same Pod:** a successfully completed init
  container is not normally rerun. Its checks are a startup gate, not a continuous
  database health monitor. Re-execution after Pod infrastructure recovery must also
  be safe, which is why automatic mode checks the database receipt.

Inspect failures with `kubectl logs <pod-name> -c provision-db` and, after a retry,
`kubectl logs <pod-name> -c provision-db --previous`. Use `kubectl describe pod
<pod-name>` for scheduling or missing-Secret events. Do not print Secret contents,
container environments or connection URLs while troubleshooting. Correct the
configuration or request DBA maintenance; never delete a receipt or migration
ledger simply to force bootstrap.

#### Production considerations and manual DBA provisioning

- The example uses one replica and `Recreate` for a simple initial installation;
  this strategy incurs downtime during updates. An init container gates **its own
  Pod**, not an entire rollout. Keep other migrators stopped during first bootstrap.
  For coordinated multi-replica installation, run a dedicated provisioning Job to
  completion before deploying ZAQ, and manage migration ordering separately.
- Every new Pod using this init-container pattern needs DBA credentials, even on
  the validation-only path. Keep Secret references explicit, restrict RBAC and
  permissions to create/edit Pods, and do not inject the DBA Secret into ZAQ. A
  completed init container does not make its configured credentials inaccessible
  to cluster administrators or users who can alter the Pod specification.
- Use appropriate network policies and TLS for your database. libpq TLS settings
  on the init container do not configure ZAQ's Ecto connection; configure both
  clients appropriately. The current URL validation compares server address/port
  and database OID. DBA and owner connections must reach the same PostgreSQL
  server; transaction poolers or load-balanced/read-replica endpoints can violate
  that assumption. Prefer a direct primary endpoint for this bootstrap path.
- **A DBA who provisions the database manually can simply omit the init container.**
  Follow the manual provisioning contract above, then start ZAQ with its owner
  `DATABASE_URL` and normal application secrets. Neither a bootstrap receipt nor
  DBA/reader credentials are required by ZAQ itself. Default startup still runs
  application migrations and checks extension prerequisites. Do not fabricate a
  receipt to make a manually provisioned database pass the automatic wrapper.
  This app-only pattern is also appropriate after a separately managed bootstrap
  Job when ongoing DBA access in application Pods is undesirable.

This is a configuration example, not a cluster-tested deployment bundle. Add your
normal resource requests/limits, probes, Service/Ingress and application storage
configuration, and validate against your database provider before rollout.

### Existing deployments and CI maintenance

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
