# ZAQ

[![Coverage Status](https://coveralls.io/repos/github/www-zaq-ai/zaq/badge.svg?branch=main)](https://coveralls.io/github/www-zaq-ai/zaq?branch=main)
[![Docs](https://img.shields.io/badge/docs-github%20pages-blue)](https://www-zaq-ai.github.io/zaq/)
[![Run](https://img.shields.io/badge/quick%20run-local%20setup-orange)](https://github.com/www-zaq-ai/zaq/wiki/Local-Installation)

AI-powered sovereign company brain. ZAQ OSS lets you access your organization's knowledge base and provides instant, cited answers to people and AI agents.

<img height="400" alt="Zaq Chat" src="https://github.com/user-attachments/assets/333d65d8-da9d-46f3-9a68-6689b58cb1b7" />

Built with [Elixir](https://elixir-lang.org/), [Phoenix](https://www.phoenixframework.org/), and [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view).

## Documentation

Project documentation is published at [www-zaq-ai.github.io/zaq](https://www-zaq-ai.github.io/zaq/) and is updated on each release.

## Architecture

ZAQ is a single Elixir/OTP application composed of five internal services. Each service runs under its own supervision tree and can be enabled or disabled per node using a role-based configuration.

```
┌──────────────────────────────────────────────────┐
│                    ZAQ (BEAM)                    │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐   │
│  │  Engine  │  │  Agent   │  │  Ingestion    │   │
│  │          │  │          │  │               │   │
│  │ Sessions │  │ RAG      │  │ Doc processing│   │
│  │ Ontology │  │ LLM      │  │ Chunking      │   │
│  │ API      │  │ Classify │  │ Embeddings    │   │
│  └──────────┘  └──────────┘  └───────────────┘   │
│                                                  │
│  ┌──────────┐  ┌──────────────────────────────┐  │
│  │ Channels │  │  Back Office (LiveView)      │  │
│  │          │  │                              │  │
│  │Mattermost│  │ Admin panel                  │  │
│  │ Slack *  │  │ Ontology management          │  │
│  │ Email *  │  │ Document management          │  │
│  └──────────┘  └──────────────────────────────┘  │
│                                                  │
│  * planned                                       │
└──────────────────────────────────────────────────┘
```

### Services

| Service       | Description                                                                    |
| ------------- | ------------------------------------------------------------------------------ |
| **Engine**    | Central orchestrator. Sessions, ontology, API routing, conversation workflows. |
| **Agent**     | AI layer. RAG retrieval, LLM interaction, classifier, knowledge gap.           |
| **Ingestion** | Document processing pipeline. Chunking, embedding generation, PGVector writes. |
| **Channels**  | Multi-channel communication adapter. Currently supports Mattermost.            |
| **BO**        | Back Office admin panel built with Phoenix LiveView.                           |

### Data Layer

- **Primary datastore** — PostgreSQL + pgvector (single `Zaq.Repo`) for sessions, chat history, ontology, documents, embeddings, and configuration.
- **Customer LLM** — On-premise, customer-provided. Connected via configurable endpoint.

## Prerequisites

- **Docker Compose**
  - Docker
  - Docker Compose plugin
- **Local Mix development**
  - Elixir `~> 1.15` (tested with Elixir 1.19.5)
  - Erlang/OTP 28
  - PostgreSQL 16+ with [pgvector](https://github.com/pgvector/pgvector) extension
  - Python 3.10+ (for PDF ingestion pipeline)
  - Node.js 20+ (optional, only for Playwright E2E tests)

## Running ZAQ

### Local Auto Installer (recommended first run)

Use the local installer to bootstrap a complete Docker-based ZAQ setup in one command.

```bash
./zaq-local.sh
```

What it does automatically:

- verifies Docker + Docker Compose are available
- creates `ingestion-volumes/documents`
- downloads the latest `docker-compose.yml`
- generates `.env` with `SECRET_KEY_BASE` and `SYSTEM_CONFIG_ENCRYPTION_KEY`
- starts ZAQ and pgvector containers in background
- opens `http://localhost:4000` and tails logs

Use this path when you want the fastest local startup.

### Docker Compose (local Docker image testing)

Use this path to explicitly test the local Docker image/runtime flow.

This path uses `docker-compose.yml` with:

- `pgvector` service (PostgreSQL + pgvector)
- `zaq` service (Phoenix release built from `Dockerfile`)
- automatic DB migration on container start

Defaults used by the Docker setup:

- ingestion volume root: `/zaq/volumes`
- default ingestion folder: `/zaq/volumes/documents`
- named volume map: `documents -> /zaq/volumes/documents`

1. Create the host folder used by the default bind mount:

```bash
mkdir -p ingestion-volumes/documents
```

2. Set a production secret key base (required by `runtime.exs`):

```bash
export SECRET_KEY_BASE="$(openssl rand -hex 64)"
```

3. Optionally override base URL and ingestion paths from your host environment:

```bash
export BASE_URL_SCHEME="http"
export BASE_URL="http://localhost:4000"

export INGESTION_VOLUMES="documents"
export INGESTION_VOLUMES_BASE="/zaq/volumes"
export INGESTION_BASE_PATH="/zaq/volumes/documents"
```

LLM, embedding, and image-to-text provider/model settings are configured from Back Office at
`/bo/system-config` and persisted in the database (`system_configs`).

4. Configure SMTP secret encryption (required to save SMTP passwords from BO):

```bash
# recommended: base64 key that decodes to exactly 32 bytes
export SYSTEM_CONFIG_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export SYSTEM_CONFIG_ENCRYPTION_KEY_ID="v1"
```

`SYSTEM_CONFIG_ENCRYPTION_KEY` accepts one of:

- raw 32-byte value
- Base64 value decoding to 32 bytes (recommended)
- 64-char hex value (32 bytes)

If the key is missing or invalid, ZAQ blocks saving sensitive SMTP settings (strict mode).

5. Build and start the stack:

```bash
docker compose up --build
```

6. Open the Back Office at [`http://localhost:4000/bo/login`](http://localhost:4000/bo/login).

To stop containers:

```bash
docker compose down
```

To stop and remove DB data volume:

```bash
docker compose down -v
```

`docker compose down -v` removes the Postgres named volume only. Files in `./ingestion-volumes` are bind-mounted and remain on disk.

### Environment Variables (required vs optional)

| Variable                            | Docker Compose default                            | Required           | Notes                                                                        |
| ----------------------------------- | ------------------------------------------------- | ------------------ | ---------------------------------------------------------------------------- |
| `DATABASE_URL`                      | `ecto://postgres:postgres@pgvector:5432/zaq_prod` | Yes (prod runtime) | Must point to your PostgreSQL + pgvector database                            |
| `SECRET_KEY_BASE`                   | none                                              | Yes (prod runtime) | Generate with `openssl rand -hex 64`                                         |
| `INGESTION_VOLUMES`                 | `documents`                                       | No                 | Optional override                                                            |
| `INGESTION_VOLUMES_BASE`            | `/zaq/volumes`                                    | No                 | Optional override                                                            |
| `INGESTION_BASE_PATH`               | `/zaq/volumes/documents`                          | No                 | Fallback path used by file preview and file serving                          |
| `OBAN_INGESTION_CONCURRENCY`        | `3`                                               | No                 | Number of document-level ingestion jobs processed in parallel                |
| `OBAN_INGESTION_CHUNKS_CONCURRENCY` | `6`                                               | No                 | Number of chunk child-jobs processed in parallel by `Zaq.Ingestion.IngestChunkWorker` |

AI model settings (LLM, embedding, image-to-text) are managed in Back Office System Config
at `/bo/system-config`, not via environment variables.

`OBAN_INGESTION_CHUNKS_CONCURRENCY` directly impacts chunk ingestion behavior:

- lower value: less concurrent title/embedding load, lower rate-limit pressure
- higher value: higher throughput, but higher load on LLM endpoints and DB
- value `1`: serial chunk worker execution per node

### Local (Mix)

1. Clone the repository and bootstrap dependencies:

```bash
git clone https://github.com/www-zaq-ai/zaq.git
cd zaq
mix setup
```

`mix setup` runs `mix deps.get`, `mix ecto.setup`, asset setup/build, and `mix zaq.python.fetch`.

2. If your PostgreSQL credentials differ from defaults, update `config/dev.exs`:

```elixir
config :zaq, Zaq.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "zaq_dev"
```

Then rerun:

```bash
mix ecto.setup
```

3. Start the application:

```bash
mix phx.server
```

Or inside IEx:

```bash
iex -S mix phx.server
```

The Back Office will be available at [`http://localhost:4000/bo/login`](http://localhost:4000/bo/login).

#### SMTP Secret Encryption (Local)

If you configure SMTP from BO and set a password, ZAQ encrypts it before storing in DB.
Configure `Zaq.System.SecretConfig` in local config (for example `config/dev.secret.exs`):

```elixir
config :zaq, Zaq.System.SecretConfig,
  encryption_key: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY"),
  key_id: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY_ID", "v1")
```

Then export a valid key:

```bash
export SYSTEM_CONFIG_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export SYSTEM_CONFIG_ENCRYPTION_KEY_ID="v1"
```

More details: `docs/system-config.md`.

#### Python Pipeline (PDF Ingestion)

`mix setup` fetches the Python scripts automatically. To set up the virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r priv/python/crawler-ingest/requirements.txt
```

PDF files uploaded for ingestion are automatically converted to clean markdown before chunking and embedding.
Image descriptions are generated when image-to-text settings are configured in Back Office
System Config (`/bo/system-config`). If provider endpoint/model/API key are empty, that step is skipped.

To re-fetch or pin the Python scripts to a specific commit:

```bash
mix zaq.python.fetch                # latest main
mix zaq.python.fetch --commit <sha> # pin to commit
```

### Startup and First Login

During `mix ecto.migrate` (or release migrations at container startup), ZAQ seeds default roles and a bootstrap Back Office account:

- Username: `admin`
- Password: `admin`

After login, you will be redirected to `/bo/change-password` and must set a new password.
If an `admin` user already exists, seeding leaves that user unchanged.

## Role-Based Node Configuration

ZAQ supports distributed deployment. Each node can run a subset of services by configuring `ROLES`.

### Configuration

In your config file (e.g. `config/dev.exs`):

```elixir
# Run all services on a single node (recommended default)
config :zaq, roles: [:all]

# Equivalent explicit list
config :zaq, roles: [:bo, :agent, :ingestion, :channels, :engine]

# Run only specific services
config :zaq, roles: [:engine, :bo]
```

Via environment variable (takes priority over config file):

```bash
ROLES=engine,agent mix phx.server
```

### Available Roles

| Role         | Starts                       |
| ------------ | ---------------------------- |
| `:all`       | All services (default)       |
| `:engine`    | `Zaq.Engine.Supervisor`      |
| `:agent`     | `Zaq.Agent.Supervisor`       |
| `:ingestion` | `Zaq.Ingestion.Supervisor`   |
| `:channels`  | `Zaq.Channels.Supervisor`    |
| `:bo`        | `ZaqWeb.Endpoint` (LiveView) |

### Multi-Node Deployment

Peer connectivity is automatic via Erlang distribution + EPMD peer discovery (no `NODES` env var required).
All nodes should run on the same host with the same `--cookie` for local discovery.

```bash
# Node 1 — BO + Engine
ROLES=engine,bo iex --sname bo@localhost --cookie zaq_secret -S mix phx.server

# Node 2 — AI services
ROLES=agent,ingestion iex --sname ai@localhost --cookie zaq_secret -S mix

# Node 3 — Communication
ROLES=channels iex --sname channels@localhost --cookie zaq_secret -S mix
```

Each node logs confirmation on successful connection:

```
[info] [PeerConnector] Connected to: ai@localhost
```

Once connected, cross-node service calls are handled automatically by `Zaq.NodeRouter`.

## Project Structure

```
lib/
├── zaq/
│   ├── application.ex      # OTP application with role-based startup + peer auto-connect
│   ├── node_router.ex      # Routes RPC calls to correct node by service role
│   ├── engine/             # Orchestration, conversations, notifications
│   ├── agent/              # RAG, LLM, classifier
│   ├── ingestion/          # Document processing, embeddings
│   ├── channels/           # Channel providers (Mattermost retrieval today)
│   ├── license/            # License loading, verification, feature gating
│   ├── embedding/          # Embedding HTTP client
│   ├── repo.ex
│   └── mailer.ex
├── zaq_web/
│   ├── live/bo/            # Back Office LiveView UI
│   ├── controllers/        # API controllers
│   ├── components/         # Shared UI components
│   ├── router.ex
│   └── endpoint.ex
└── zaq.ex
```

## Releases

Releases are automated with a release PR gate powered by [release-please](https://github.com/googleapis/release-please-action).

- This repository follows a trunk-based flow: `feature/*` and `hotfix/*` branches open PRs into `main`
- Every PR title must follow Conventional Commits (`feat:`, `fix:`, `chore:`, etc.)
- Merges into `main` update or create a release PR instead of releasing immediately
- Merging the release PR bumps `mix.exs` version, creates a git tag, and publishes a GitHub Release

### First-Time Setup

1. Optionally add repository secret `RELEASE_PLEASE_TOKEN` (PAT with repo/workflow permissions). The workflow falls back to `GITHUB_TOKEN` when it is not set.
2. Ensure GitHub Actions are allowed to create and approve pull requests
3. Create a baseline tag on `main` matching `mix.exs` (`v0.1.0`)

## Container Images

On every published release, GitHub Actions builds and pushes a Docker image to GitHub Container Registry:

- `ghcr.io/www-zaq-ai/zaq:vX.Y.Z`
- `ghcr.io/www-zaq-ai/zaq:X.Y.Z`
- `ghcr.io/www-zaq-ai/zaq:X.Y`
- `ghcr.io/www-zaq-ai/zaq:X`
- `ghcr.io/www-zaq-ai/zaq:latest` (only for stable releases)

## Community

Join the [ZAQ Discord](https://discord.gg/rDUeWP5GbD) to ask questions, share feedback, and connect with other users and contributors.

## Contributing

See `docs/workflows.md` for branching, commit conventions, and the PR workflow.

## License

License details are maintained by the repository owners.
