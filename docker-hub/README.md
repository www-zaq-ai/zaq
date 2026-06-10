# ZAQ — All-in-One Docker Image

A single Docker image that bundles everything you need to run ZAQ:

- **ZAQ** — AI-powered company brain (Elixir/Phoenix)
- **ParadeDB** — PostgreSQL 16 with full-text and vector search extensions
- **Python ingestion crawler** — for document processing

No external database, no docker-compose, no configuration required.

---

## Quick Start

```bash
docker run -d \
  --name zaq \
  -p 4000:4000 \
  -v zaq-pgdata:/var/lib/postgresql/data \
  -v zaq-volumes:/zaq/volumes \
  docker-hub-image/zaq:latest
```

Open [http://localhost:4000](http://localhost:4000) in your browser.

On first boot you will be prompted to set your admin password — no default credentials needed.

---

## Volumes

| Volume | Purpose |
|---|---|
| `zaq-pgdata` | PostgreSQL data (conversations, config, embeddings) |
| `zaq-volumes` | Ingestion documents |

> **Warning:** If you run without named volumes, data will be lost when the container is removed.
> Always use `-v zaq-pgdata:/var/lib/postgresql/data -v zaq-volumes:/zaq/volumes`.

---

## Environment Variables

All variables have sensible defaults. Override only what you need.

| Variable | Default | Description |
|---|---|---|
| `PORT` | `4000` | HTTP port ZAQ listens on |
| `PHX_HOST` | `localhost` | Public hostname (set to your domain in production) |
| `POSTGRES_DB` | `zaq_prod` | PostgreSQL database name |
| `POSTGRES_USER` | `postgres` | PostgreSQL user |
| `POSTGRES_PASSWORD` | `postgres` | PostgreSQL password |
| `DATABASE_URL` | auto | Ecto connection URL (derived from above) |
| `INGESTION_VOLUMES` | `documents` | Comma-separated ingestion volume names |
| `INGESTION_VOLUMES_BASE` | `/zaq/volumes` | Base path for ingestion volumes |

`SECRET_KEY_BASE` and `SYSTEM_CONFIG_ENCRYPTION_KEY` are **auto-generated on first boot** and persisted inside the `zaq-pgdata` volume. You do not need to set them.

To migrate an existing installation, supply your existing keys:

```bash
docker run -d \
  --name zaq \
  -p 4000:4000 \
  -e SECRET_KEY_BASE_OVERRIDE="your-existing-key" \
  -e SYSTEM_CONFIG_ENCRYPTION_KEY_OVERRIDE="your-existing-key" \
  -v zaq-pgdata:/var/lib/postgresql/data \
  -v zaq-volumes:/zaq/volumes \
  docker-hub-image/zaq:latest
```

---

## LLM & Embedding Configuration

LLM providers, embedding models, and all AI settings are configured through the ZAQ back-office UI at `/bo/system-config` after first login. Nothing needs to be set at container startup.

---

## Updating

```bash
docker pull docker-hub-image/zaq:latest
docker stop zaq && docker rm zaq
docker run -d \
  --name zaq \
  -p 4000:4000 \
  -v zaq-pgdata:/var/lib/postgresql/data \
  -v zaq-volumes:/zaq/volumes \
  docker-hub-image/zaq:latest
```

Your data is safe in the named volumes and migrations run automatically on startup.
