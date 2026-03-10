# CLAUDE.md — ZAQ Project Context

This file is for LLMs (Claude, etc.) to get up to speed on ZAQ quickly.
Read this before making any changes.

---

## What is ZAQ

AI-powered company brain. ZAQ ingests documents, builds a knowledge base, and answers
questions from humans and AI agents with cited responses. It is deployed on-premise,
connecting to a customer-provided LLM endpoint.

---

## Tech Stack

| Layer       | Technology                                      |
|-------------|-------------------------------------------------|
| Language    | Elixir 1.19.5 / Erlang OTP 28                  |
| Web         | Phoenix 1.7, Phoenix LiveView                   |
| Database    | PostgreSQL 16+ with pgvector extension          |
| Jobs        | Oban (background job processing)                |
| Assets      | Node.js 20+                                     |
| LLM         | Customer-provided, connected via config endpoint|

---

## Project Structure

```
lib/
├── zaq/
│   ├── accounts/         # Users, roles, auth context
│   ├── agent/            # RAG, LLM, answering, retrieval
│   ├── channels/         # Mattermost adapter
│   ├── embedding/        # Embedding client (standalone, not under agent/)
│   ├── engine/           # ⚠️ NOT STARTED — placeholder only, no files
│   ├── ingestion/        # Document processing, chunking, Oban jobs
│   ├── license/          # License loading, verification, feature gating
│   ├── document_processor/ # Behaviour definition for doc processors
│   ├── node_router.ex    # Routes RPC calls to correct node by role
│   ├── application.ex    # Role-based OTP startup + peer node auto-connect
│   ├── repo.ex
│   └── mailer.ex
├── zaq_web/
│   ├── live/bo/
│   │   ├── accounts/     # Users + Roles CRUD LiveViews (✅ functional)
│   │   ├── ai/           # Ingestion, Ontology, Prompt Templates, Diagnostics (✅ functional)
│   │   ├── communication/# Channels, History, Playground LiveViews
│   │   └── system/       # Change password, License LiveViews
│   ├── controllers/      # API + BO session controllers
│   ├── plugs/auth.ex     # Auth plug
│   └── router.ex
```

---

## Service Status

| Service       | Status        | Notes                                                  |
|---------------|---------------|--------------------------------------------------------|
| **Agent**     | ✅ Functional  | RAG, LLM, answering, retrieval, logprobs, token est.   |
| **Ingestion** | ✅ Functional  | Chunking, embeddings, Oban workers, PGVector writes    |
| **Channels**  | ✅ Functional  | Mattermost only. Slack + Email are planned, not started|
| **BO**        | ✅ Functional  | Auth, accounts, AI pages, communication pages          |
| **Engine**    | ❌ Not started | Directory exists but is empty. Do not assume any logic.|

---

## BO (Back Office) — What's Done

### Auth (✅ complete)
- Login/logout, session, CSRF-protected
- `must_change_password` enforcement on first login
- Auth plug protects all `/bo/*` routes
- `on_mount` AuthHook injects `current_user` into all LiveViews
- Super admin seeded on boot from `config/dev.secrets.exs`

### Accounts (✅ complete)
- Users CRUD: list, create, edit, delete
- Roles CRUD: list, create (with JSON meta), edit, delete
- Context: `Zaq.Accounts`

### AI Pages (✅ functional)
- `ingestion_live` — document ingestion management
- `ontology_live` — ontology management
- `prompt_templates_live` — prompt template management
- `ai_diagnostics_live` — AI diagnostics

### Playground (✅ functional)
- Full RAG pipeline: PromptGuard → Retrieval → QueryExtraction → Answering → PromptGuard
- All agent/ingestion calls go through `Zaq.NodeRouter` — works in both single-node and multi-node
- Conversation history maintained per session

### What's Left for BO
- [ ] Remember me (persistent session)
- [ ] Role-based authorization plug (restrict routes by role)
- [ ] Flash messages styled consistently
- [ ] Password reset flow
- [ ] Audit log, session expiry, rate limiting, 2FA (nice to have)

---

## Multi-Node / Role-Based Startup

### How roles work
Services are started based on the `:roles` config or `ROLES` env var.
`ROLES` env var takes priority over `config/dev.exs`.

```elixir
# config/dev.exs — default for single-node dev
config :zaq, roles: [:bo, :agent, :ingestion, :channels]
```

```bash
# Override per terminal session
ROLES=agent,ingestion iex --sname ai@localhost --cookie zaq_dev -S mix
ROLES=bo NODES=ai@localhost iex --sname bo@localhost --cookie zaq_dev -S mix phx.server
```

### NODES env var
`NODES` is a comma-separated list of peer nodes to auto-connect on boot.
The application calls `Node.connect/1` for each after the supervision tree starts.

```bash
NODES=ai@localhost,channels@localhost iex --sname bo@localhost --cookie zaq_dev -S mix phx.server
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

### Verifying what started
```elixir
Process.whereis(Zaq.Agent.Supervisor)      # PID if running, nil if not
Process.whereis(Zaq.Ingestion.Supervisor)
Process.whereis(Zaq.Channels.Supervisor)
Node.list()                                # connected peer nodes
```

---

## NodeRouter (`Zaq.NodeRouter`)

All cross-service calls from BO (e.g. playground → agent, playground → ingestion)
go through `Zaq.NodeRouter` instead of direct module calls.

```elixir
# DO NOT do this in BO LiveViews — breaks multi-node
Retrieval.ask(question, opts)

# DO this instead — works single-node and multi-node
NodeRouter.call(:agent, Retrieval, :ask, [question, opts])
```

`NodeRouter.call/4` checks `Process.whereis/1` locally first, then `:rpc.call/4`
on peer nodes. Falls back to local call transparently in single-node dev.

---

## Key Conventions

### Elixir / Phoenix
- Contexts live in `lib/zaq/` (e.g. `Zaq.Accounts`, `Zaq.Ingestion`)
- LiveViews live in `lib/zaq_web/live/bo/<section>/`
- Each LiveView has a paired `.html.heex` template file
- Background jobs use Oban workers under `lib/zaq/ingestion/`
- Behaviours are defined separately (e.g. `document_processor/behaviour.ex`)

### Naming
- LiveView modules: `ZaqWeb.Live.BO.<Section>.<Name>Live`
- Context functions follow Ecto conventions: `create_x/1`, `update_x/2`, `delete_x/1`
- Schema modules: `Zaq.<Context>.<Entity>` (e.g. `Zaq.Accounts.User`)

### Code Quality
- Run `mix format --check-formatted` before committing
- Run `mix test` before committing
- Do not submit PRs that break existing tests

---

## Data Layer

- **Primary DB** — PostgreSQL. Sessions, accounts, ontology, config.
- **Vector DB** — PostgreSQL + PGVector. Embeddings, documents, knowledge gaps.
- **LLM** — Customer-provided on-premise endpoint, configured per deployment.
- **Embedding client** — `lib/zaq/embedding/client.ex` (standalone module)

---

## Dev Setup

```bash
git clone https://github.com/www-zaq-ai/zaq.git
cd zaq
mix setup          # deps.get + ecto.setup + assets
mix phx.server     # starts at http://localhost:4000/bo
```

Back Office: `http://localhost:4000/bo`

---

## What NOT to Do

- **Do not add logic to `lib/zaq/engine/`** — it is not started yet, discuss first
- **Do not assume Slack or Email channels exist** — Mattermost only
- **Do not move `embedding/client.ex` under `agent/`** without discussion
- **Do not add new BO routes without updating the auth plug and router**
- **Do not hardcode LLM endpoints** — they are customer-configured
- **Do not call Agent or Ingestion modules directly from BO LiveViews** — use `NodeRouter.call/4`