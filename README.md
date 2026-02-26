# ZAQ

AI-powered company brain that updates itself. ZAQ continuously maintains your organization's knowledge base and provides instant, cited answers to people and AI agents.

Built with [Elixir](https://elixir-lang.org/), [Phoenix](https://www.phoenixframework.org/), and [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view).

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

| Service       | Description                                                        |
|---------------|--------------------------------------------------------------------|
| **Engine**    | Central orchestrator. Sessions, ontology, API routing, licensing.  |
| **Agent**     | AI layer. RAG retrieval, LLM interaction, classifier, knowledge gap. |
| **Ingestion** | Document processing pipeline. Chunking, embedding generation, PGVector writes. |
| **Channels**  | Multi-channel communication adapter. Currently supports Mattermost. |
| **BO**        | Back Office admin panel built with Phoenix LiveView.               |

### Data Layer

- **Engine DB** — PostgreSQL. Sessions, chat history, ontology, configuration.
- **Agent DB** — PostgreSQL + PGVector. Embeddings, documents, knowledge gap records.
- **Customer LLM** — On-premise, customer-provided. Connected via configurable endpoint.

## Prerequisites

- Elixir 1.17+
- Erlang/OTP 27+
- PostgreSQL 16+ with [pgvector](https://github.com/pgvector/pgvector) extension
- Node.js 20+ (for asset compilation)

## Setup

Clone the repository and install dependencies:

```bash
git clone https://github.com/www-zaq-ai/zaq.git
cd zaq
mix setup
```

This runs `mix deps.get`, creates the database, runs migrations, and installs assets.

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

## Role-Based Node Configuration

ZAQ supports distributed deployment. Each node can run a subset of services by configuring roles.

### Configuration

In your config file (e.g. `config/dev.exs`):

```elixir
# Run all services (default)
config :zaq, roles: [:all]

# Run only specific services
config :zaq, roles: [:engine, :bo]
```

Via environment variable:

```bash
ROLES=engine,agent mix phx.server
```

### Available Roles

| Role         | Starts                        |
|--------------|-------------------------------|
| `:all`       | All services (default)        |
| `:engine`    | `Zaq.Engine.Supervisor`       |
| `:agent`     | `Zaq.Agent.Supervisor`        |
| `:ingestion` | `Zaq.Ingestion.Supervisor`    |
| `:channels`  | `Zaq.Channels.Supervisor`     |
| `:bo`        | `ZaqWeb.Endpoint` (LiveView)  |

### Example: Multi-Node Deployment

```bash
# Node 1 — API + Admin
ROLES=engine,bo elixir --sname engine@localhost -S mix phx.server

# Node 2 — AI services
ROLES=agent,ingestion elixir --sname ai@localhost -S mix phx.server

# Node 3 — Communication
ROLES=channels elixir --sname channels@localhost -S mix phx.server
```

## Project Structure

```
lib/
├── zaq/
│   ├── application.ex      # OTP application with role-based startup
│   ├── engine/             # Orchestration, sessions, ontology
│   ├── agent/              # RAG, LLM, classifier
│   ├── ingestion/          # Document processing, embeddings
│   ├── channels/           # Mattermost, Slack, Email adapters
│   ├── bo/                 # Back Office business logic (contexts)
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

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

Please ensure your code passes `mix format --check-formatted` and `mix test` before submitting.

## License

See [LICENSE](LICENSE) for details.