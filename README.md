# ZAQ

![Coverage](https://img.shields.io/coverallsCoverage/github/www-zaq-ai/zaq?branch=main)
[![Docs](https://img.shields.io/badge/docs-github%20pages-blue)](https://www-zaq-ai.github.io/zaq/)

AI-powered company brain that updates itself. ZAQ continuously maintains your organization's knowledge base and provides instant, cited answers to people and AI agents.

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
| **Engine**    | Central orchestrator. Sessions, ontology, API routing, licensing.              |
| **Agent**     | AI layer. RAG retrieval, LLM interaction, classifier, knowledge gap.           |
| **Ingestion** | Document processing pipeline. Chunking, embedding generation, PGVector writes. |
| **Channels**  | Multi-channel communication adapter. Currently supports Mattermost.            |
| **BO**        | Back Office admin panel built with Phoenix LiveView.                           |

### Data Layer

- **Engine DB** — PostgreSQL. Sessions, chat history, ontology, configuration.
- **Agent DB** — PostgreSQL + PGVector. Embeddings, documents, knowledge gap records.
- **Customer LLM** — On-premise, customer-provided. Connected via configurable endpoint.

## Prerequisites

- Elixir 1.19.5
- Erlang/OTP 28
- PostgreSQL 16+ with [pgvector](https://github.com/pgvector/pgvector) extension
- Node.js 20+ (for asset compilation)
- Python 3.10+ (for PDF ingestion pipeline)

## Setup

Clone the repository and install dependencies:

```bash
git clone https://github.com/www-zaq-ai/zaq.git
cd zaq
mix setup
```

This runs `mix deps.get`, creates the database, runs migrations, installs assets, and fetches the Python pipeline scripts.

### Python Pipeline (PDF Ingestion)

`mix setup` fetches the Python scripts automatically. To set up the virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r priv/python/crawler-ingest/requirements.txt
```

PDF files uploaded for ingestion are automatically converted to clean markdown before chunking and embedding. Image descriptions are generated via Scaleway Pixtral when `SCALEWAY_API_KEY` is set — otherwise that step is skipped.

```bash
# Optional — enables image-to-text descriptions in PDFs
export SCALEWAY_API_KEY=your-key-here
```

To re-fetch or pin the Python scripts to a specific commit:

```bash
mix zaq.python.fetch                      # latest main
mix zaq.python.fetch --commit <sha>       # pin to commit
```

### Database

Make sure PostgreSQL is running and configure your credentials in `config/dev.exs`:

```elixir
config :zaq, Zaq.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "zaq_dev"
```

Then create and migrate:

```bash
mix ecto.setup
```

### Running

Start the application:

```bash
mix phx.server
```

Or inside IEx:

```bash
iex -S mix phx.server
```

The Back Office will be available at [`http://localhost:4000/bo`](http://localhost:4000/bo).

### Startup and First Login

On first startup after running migrations, ZAQ seeds default roles and a bootstrap Back Office account:

- Username: `admin`
- Password: `admin`

After login, you will be redirected to `/bo/change-password` and must set a new password.
If an `admin` user already exists, startup seeding leaves that user unchanged.

## Role-Based Node Configuration

ZAQ supports distributed deployment. Each node can run a subset of services by configuring roles.

### Configuration

In your config file (e.g. `config/dev.exs`):

```elixir
# Run all services on a single node (default)
config :zaq, roles: [:bo, :agent, :ingestion, :channels]

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

Nodes auto-connect to peers on boot using the `NODES` env var.
All nodes must share the same `--cookie` for Erlang distribution to work.

```bash
# Node 1 — AI services (start first)
ROLES=agent,ingestion iex --sname ai@localhost --cookie zaq_secret -S mix

# Node 2 — API + Admin (auto-connects to ai node)
ROLES=engine,bo NODES=ai@localhost iex --sname bo@localhost --cookie zaq_secret -S mix phx.server

# Node 3 — Communication (auto-connects to both)
ROLES=channels NODES=ai@localhost,bo@localhost iex --sname channels@localhost --cookie zaq_secret -S mix
```

`NODES` accepts a comma-separated list of node names. Each node logs a confirmation on successful connection:

```
[info] Connected to peer node: ai@localhost
```

Once connected, cross-node service calls are handled automatically by `Zaq.NodeRouter`.

## Project Structure

```
lib/
├── zaq/
│   ├── application.ex      # OTP application with role-based startup + peer auto-connect
│   ├── node_router.ex      # Routes RPC calls to correct node by service role
│   ├── engine/             # Orchestration, sessions, ontology (not started yet)
│   ├── agent/              # RAG, LLM, classifier
│   ├── ingestion/          # Document processing, embeddings
│   ├── channels/           # Mattermost, Slack, Email adapters
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

1. Add repository secret `RELEASE_PLEASE_TOKEN` (a PAT with repo/workflow permissions)
2. Ensure GitHub Actions are allowed to create and approve pull requests
3. Create a baseline tag on `main` matching `mix.exs` (`v0.1.0`)

## Container Images

On every published release, GitHub Actions builds and pushes a Docker image to GitHub Container Registry:

- `ghcr.io/www-zaq-ai/zaq:vX.Y.Z`
- `ghcr.io/www-zaq-ai/zaq:X.Y.Z`
- `ghcr.io/www-zaq-ai/zaq:X.Y`
- `ghcr.io/www-zaq-ai/zaq:X`
- `ghcr.io/www-zaq-ai/zaq:latest` (only for stable releases)

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
   - For urgent post-release fixes, use `hotfix/my-fix` instead
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin <your-branch-name>`)
5. Open a Pull Request targeting `main`

Please ensure your code passes `mix format --check-formatted` and `mix test` before submitting.

## License

License details are maintained by the repository owners.
