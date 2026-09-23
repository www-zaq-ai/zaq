# Deploying ZAQ

This guide covers local Docker setup and the additional configuration required for a server deployment. For a source-based development environment, use [development setup](../dev-setup.md). For model and credential settings, use [system configuration](../services/system-config.md).

## Local auto installer

On macOS or Linux, install and start Docker with the Docker Compose plugin, then run:

```bash
git clone https://github.com/www-zaq-ai/zaq.git
cd zaq
./zaq-local.sh
```

The [installer](../../zaq-local.sh) checks its command prerequisites, downloads a Compose file from its configured GitHub Gist, creates `ingestion-volumes/documents`, generates `.env` secrets, and starts the stack. It opens `http://localhost:4000` and tails logs. Ctrl+C exits the log viewer, not the containers.

The downloaded Compose file is separate from the repository's source-build configuration. Run the installer in a dedicated checkout/directory: its setup writes `docker-compose.yml` and `.env`. Preserve existing configuration and secrets before reinstalling. Subsequent runs offer management options for an existing installation.

The installer does not provision database extensions. On an unprovisioned database,
startup migrations stop with setup-script instructions. Provision the database with
a DBA connection as described in [database setup](../database-setup.md), then rerun
the installer. Check the downloaded Compose file for its database name and credentials;
the repository Compose example below may not match it.

Complete [first-run setup](#first-run-setup), including saving the Disk volume declaration. The installer creates the folder, not the data-source declaration or a local model server.

This is a local HTTP setup. Do not expose it on a LAN or public domain without the [production HTTPS configuration](#production-deployment-and-https).

## Docker Compose

Use this path to build the application from the checked-out source rather than use the installer-downloaded stack. The repository's [docker-compose.yml](../../docker-compose.yml) starts PostgreSQL with pgvector and a Phoenix release built from the [Dockerfile](../../Dockerfile). Database migrations run at container startup.

From the repository root:

```bash
mkdir -p ingestion-volumes/documents
export SECRET_KEY_BASE="$(openssl rand -hex 64)"
export SYSTEM_CONFIG_ENCRYPTION_KEY="$(openssl rand -base64 32)"
docker compose up -d --wait postgres
docker compose exec -T postgres psql -X --set ON_ERROR_STOP=1 -U postgres -d zaq_prod < scripts/setup_postgres_extensions.sql
docker compose up --build
```

Start PostgreSQL and provision extensions **before** ZAQ starts and runs migrations.
The example provisions the repository Compose database with its local administrator
credentials. For an external database or ParadeDB, choose the appropriate script
and DBA connection from [database setup](../database-setup.md). Server extension
packages must already be available. In production, configure `DATABASE_URL` with
a non-superuser owner of the database and application objects, not the bootstrap
administrator; the bundled Compose credentials are local-development defaults.

**Keep these keys stable across restarts.** Store them securely in your deployment environment or a protected, untracked `.env` file. Do not regenerate the encryption key on an existing installation: previously encrypted credentials require their original key. The key must represent exactly 32 bytes; Base64 is recommended. Raw 32-byte and 64-character hex values are also accepted. Production startup requires a valid encryption key, not just SMTP configuration. See [secret configuration](../services/system-config.md#smtp-password-encryption).

Open [http://localhost:4000/bo/login](http://localhost:4000/bo/login). HTTP is exempted from production SSL enforcement only for request hosts `localhost` and `127.0.0.1`. Using a server IP or domain requires HTTPS setup.

### First-run setup

Migrations seed default roles and a bootstrap Back Office account named `admin`. On a fresh installation, the first-login flow redirects to `/bo/change-password` to set an email and a new password. Existing administrator accounts are not overwritten.

1. Complete first-login setup.
2. Configure AI provider credentials and model settings in Back Office **System Config** (`/bo/system-config`). LLM, embedding, and image-to-text settings are database-backed, not `LLM_*` environment variables. Configure embedding settings before ingesting documents.
3. For mounted files, open **Data Sources → Disk** (`/bo/channels/data_source/disk`). Save a volume with **Name** `documents`, **Relative path** `documents`, and select it as the **Default**. Ensure the data source is enabled.
4. Configure a conversation-enabled agent under **Agents**, then open **Chat**. Add knowledge and tools appropriate to its task.

### Persistent storage

The source-build Compose file uses:

- PostgreSQL named volume: `pgdata`.
- Host bind mount: `./ingestion-volumes:/zaq/volumes`.
- Runtime storage base: `/zaq/volumes`.
- Database-backed Disk volume declarations, configured in Back Office.

The `documents` declaration points to `/zaq/volumes/documents` in the container, backed by `./ingestion-volumes/documents` on the host. To expose the mounted root, explicitly use `.` as the relative path. Paths must be relative to the storage base; absolute paths and `..` components are rejected. Removing a declaration makes its path inaccessible through that declaration but does not delete the files.

If changing `STORAGE_VOLUMES_BASE`, change the bind-mount destination together with it. The environment variable alone does not move the mount. Leaving `STORAGE_VOLUMES` empty does not create a Disk data source or expose the root automatically.

### Stop or remove containers

```bash
docker compose down
```

To also **delete the PostgreSQL data volume**:

```bash
docker compose down -v
```

The second command destroys database state. Bind-mounted files in `./ingestion-volumes` remain on disk. Back up the database, mounted files, and encryption keys before destructive maintenance.

## Environment settings

Defaults below refer to the repository Compose file and [production runtime configuration](../../config/runtime.exs), not necessarily the installer-downloaded stack.

| Variable | Default / requirement | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | Required in production; Compose supplies `ecto://postgres:postgres@postgres:5432/zaq_prod` | PostgreSQL connection; replace example credentials for production |
| `SECRET_KEY_BASE` | Required | Phoenix signing/encryption secret |
| `SYSTEM_CONFIG_ENCRYPTION_KEY` | Required in production | Encryption key for stored credentials and other sensitive fields |
| `SYSTEM_CONFIG_ENCRYPTION_KEY_ID` | Runtime default `v1` | Key metadata; add explicit Compose passthrough if overriding |
| `PHX_HOST` | Compose: `localhost`; runtime fallback: `example.com` | Public hostname only, without scheme, port, or path |
| `STORAGE_VOLUMES_BASE` | `/zaq/volumes` | Filesystem base for saved Disk volume relative paths |
| `STORAGE_VOLUMES` | Empty in Compose | Legacy one-time import input; leave empty for new installations |
| `OBAN_INGESTION_CONCURRENCY` | Runtime: `3` | Concurrent document ingestion jobs |
| `OBAN_INGESTION_CHUNKS_CONCURRENCY` | Runtime: `6` | Concurrent chunk jobs; reduce to lower provider load/rate-limit pressure |
| `WORKFLOWS_ENABLED` | Production runtime: `false` | Opt-in workflow runtime and UI |

Not every runtime setting is passed through by the supplied Compose file. For example, to change chunk concurrency, add `OBAN_INGESTION_CHUNKS_CONCURRENCY: "${OBAN_INGESTION_CHUNKS_CONCURRENCY:-6}"` under the `zaq` service's `environment` block. A shell variable or `.env` entry has no effect unless Compose passes it into the container.

Disk declarations belong in **Data Sources → Disk**, not System Config. Model and provider settings belong in **System Config**, not infrastructure environment variables.

### Upgrading legacy storage configuration

`STORAGE_VOLUMES` accepts comma-separated names such as `documents,manuals`, imported with matching relative paths during the one-time Disk volume migration. Empty input or `/` imports no declarations. Existing nonempty Disk declarations are preserved. Changing the variable after the migration does not update the database; use Back Office for subsequent changes.

### Enable workflows

Workflows are disabled by default in production. To opt in, add this entry to the `zaq` service's `environment` block:

```yaml
WORKFLOWS_ENABLED: "true"
```

Recreate the container with `docker compose up -d`. For non-Compose releases, set `WORKFLOWS_ENABLED=true` in the process environment. See [workflow authoring](../guides/workflows-guide.md) for graph construction, tool steps, conditions, and human approval checkpoints.

## Production deployment and HTTPS

The Docker image is a production Phoenix release even when used locally. Production configuration enforces HTTPS and HSTS for non-excluded hosts. Its public endpoint URL uses **HTTPS on port 443**, but the supplied Compose release listens on **HTTP on port 4000**. Setting `PHX_HOST` does not install certificates or create an HTTPS listener.

### 1. Set the public hostname

Configure DNS to reach your TLS reverse proxy and set the hostname in your shell or Compose `.env`:

```bash
export PHX_HOST=zaq.company.com
```

The repository Compose file passes `${PHX_HOST:-localhost}` into ZAQ. Older or installer-downloaded files may hardcode `PHX_HOST: "localhost"`; replace that literal with `${PHX_HOST:-localhost}` or your public hostname. An exported variable cannot override a hardcoded Compose value. Recreate the container after environment changes (`docker compose up -d`).

### 2. Terminate TLS at a reverse proxy

Put Caddy, nginx, or Traefik in front of ZAQ with a certificate trusted by clients. Serve HTTPS on port 443 and redirect public HTTP traffic to HTTPS. Forward requests over HTTP to ZAQ, preserve the public `Host` header, and support WebSocket upgrades for LiveView. The proxy must **set/overwrite `X-Forwarded-Proto: https`** for TLS requests; ZAQ uses it to recognize secure requests.

For example, with Caddy installed on the Docker host:

```text
zaq.company.com {
    reverse_proxy 127.0.0.1:4000
}
```

Caddy handles TLS, forwarded headers, and WebSockets. Public certificate issuance requires suitable DNS and reachable challenge ports. Private deployments need an appropriately trusted internal certificate setup.

### 3. Restrict backend access

For the host-based Caddy example, replace ZAQ's `"4000:4000"` mapping with `"127.0.0.1:4000:4000"`. A containerized proxy should use a private Docker network without publishing ZAQ's port publicly.

Do not let untrusted clients reach the backend directly: forwarded scheme headers are trusted, and loopback request hosts are exempt from SSL enforcement. The supplied Compose file is for local testing; also remove public PostgreSQL port exposure and replace its example database credentials for production.

### 4. Verify access and callbacks

Open `https://zaq.company.com/bo/login`. Verify login and LiveView navigation without redirect loops or WebSocket/origin errors. For integrations requiring callbacks, also set **System Config → Global → Base URL** to the public HTTPS URL. That database setting is separate from `PHX_HOST`.

### Troubleshooting

- **Redirects to `https://localhost/...` or `https://example.com/...`:** correct the container's `PHX_HOST` and recreate it. Phoenix SSL redirects default to the configured endpoint hostname, not necessarily the incoming request hostname.
- **Repeated redirects behind a proxy:** verify it overwrites `X-Forwarded-Proto` and preserves the public host.
- **TLS errors at `https://server:4000`:** that port serves HTTP, not TLS. Use the proxy's HTTPS endpoint.
- **Changing `BASE_URL` or `BASE_URL_SCHEME` does not fix SSL behavior:** neither disables enforcement nor changes the endpoint's HTTPS/443 configuration. `force_ssl` is compile-time configuration; changing it requires rebuilding. Do not disable it for production.

Direct TLS termination in Phoenix is an alternative but requires an `https` listener and certificate/key configuration as described in [runtime.exs](../../config/runtime.exs), then rebuilding. The supplied Compose setup does not configure it.

## Published container images

Published releases build images in GitHub Container Registry:

- `ghcr.io/www-zaq-ai/zaq:vX.Y.Z`
- `ghcr.io/www-zaq-ai/zaq:X.Y.Z`
- `ghcr.io/www-zaq-ai/zaq:X.Y`
- `ghcr.io/www-zaq-ai/zaq:X`
- `ghcr.io/www-zaq-ai/zaq:latest` (stable releases only)

Use a versioned tag for reproducible deployments. The repository Compose file builds from source; selecting a published image is a separate deployment choice. Maintainers can find the release process in [Git workflows](../workflows.md#releases).
