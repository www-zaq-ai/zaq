# CLAUDE.md — ZAQ Project Context

## ⚡ Execution Rule
ALL related operations MUST be concurrent in a single message: batch TodoWrite, Task spawns, file reads/writes, and bash commands together. Never split related operations across messages.

---

## What is ZAQ
AI-powered company brain. Ingests documents, builds a knowledge base, answers questions from humans and AI agents with cited responses. Deployed on-premise with a customer-provided LLM endpoint.

---

## Tech Stack
| Layer    | Technology |
| -------- | ---------- |
| Language | Elixir 1.19.5 / Erlang OTP 28 |
| Web      | Phoenix 1.7, Phoenix LiveView |
| Database | PostgreSQL 16+ with pgvector |
| Jobs     | Oban |
| Assets   | Node.js 20+ |
| LLM      | Customer-provided, configured per deployment |

---

## Project Structure
```
lib/
├── zaq/
│   ├── accounts/         # Users, roles, auth
│   ├── agent/            # RAG, LLM, answering, retrieval
│   ├── channels/         # Shared infra + adapter implementations
│   │   ├── ingestion/    # Google Drive, SharePoint (not yet implemented)
│   │   └── retrieval/    # Mattermost ✅, Slack/Email planned
│   ├── embedding/        # Embedding client (standalone)
│   ├── engine/           # Orchestrator — adapter contracts + supervisors
│   ├── ingestion/        # Document processing, chunking, Oban jobs
│   ├── license/          # License verification, feature gating
│   ├── node_router.ex    # Routes RPC calls by role
│   └── application.ex   # Role-based OTP startup
├── zaq_web/
│   ├── live/bo/
│   │   ├── accounts/     # Users + Roles CRUD
│   │   ├── ai/           # Ingestion, Ontology, Prompt Templates, Diagnostics
│   │   ├── communication/# Channels, History, Playground
│   │   └── system/       # Password, License
│   ├── controllers/
│   ├── plugs/auth.ex
│   └── router.ex
```

---

## Key Conventions

- Contexts: `lib/zaq/` (e.g. `Zaq.Accounts`, `Zaq.Ingestion`)
- LiveViews: `lib/zaq_web/live/bo/<section>/` with paired `.html.heex`
- LiveView modules: `ZaqWeb.Live.BO.<Section>.<n>Live`
- Context functions: `create_x/1`, `update_x/2`, `delete_x/1`
- Schemas: `Zaq.<Context>.<Entity>` (e.g. `Zaq.Accounts.User`)
- Channel adapters: `Zaq.Channels.<Kind>.<Provider>`
- Background jobs: Oban workers under `lib/zaq/ingestion/`
- Run `mix format --check-formatted` and `mix test` before committing

---

## NodeRouter — CRITICAL
All cross-service calls from BO go through `Zaq.NodeRouter`, not direct module calls.

```elixir
# ❌ WRONG — breaks multi-node
Retrieval.ask(question, opts)

# ✅ CORRECT
NodeRouter.call(:agent, Retrieval, :ask, [question, opts])
```

`NodeRouter.call/4` checks locally first, then `:rpc.call/4` on peer nodes.

---

## Multi-Node Roles
Services start based on `:roles` config or `ROLES` env var (`ROLES` takes priority).

| Role         | Starts |
| ------------ | ------ |
| `:all`       | All services (default) |
| `:engine`    | `Zaq.Engine.Supervisor` |
| `:agent`     | `Zaq.Agent.Supervisor` |
| `:ingestion` | `Zaq.Ingestion.Supervisor` |
| `:channels`  | `Zaq.Channels.Supervisor` |
| `:bo`        | `ZaqWeb.Endpoint` |

---

## Engine
Orchestrates ZAQ. Owns behaviour contracts and adapter lifecycle.

- `Zaq.Engine.IngestionChannel` — contract for ingestion adapters
- `Zaq.Engine.RetrievalChannel` — contract for retrieval adapters
- `Zaq.Engine.IngestionSupervisor` / `RetrievalSupervisor` — loads configs from DB, starts adapters dynamically

Registered adapters:
- Retrieval: `mattermost` ✅, `slack` / `email` (not implemented)
- Ingestion: `google_drive` / `sharepoint` (not implemented)

---

## Sub-Agents
15 agents in `.claude/agents/`. Shared memory at `.swarm/memory.json`.

`project-planner` · `api-developer` · `frontend-developer` · `tdd-specialist` · `code-reviewer` · `debugger` · `refactor` · `doc-writer` · `security-scanner` · `devops-engineer` · `product-manager` · `marketing-writer` · `api-documenter` · `test-runner` · `shadcn-ui-builder`

---

## What NOT To Do
- Don't add adapters to `Zaq.Channels.Supervisor` — Engine manages adapter lifecycle
- Don't define behaviour contracts in `lib/zaq/channels/` — they belong in `lib/zaq/engine/`
- Don't assume Slack, Email, or ingestion adapters exist — only Mattermost is implemented
- Don't move `embedding/client.ex` under `agent/` without discussion
- Don't add BO routes without updating auth plug and router
- Don't hardcode LLM endpoints — customer-configured
- Don't call Agent or Ingestion modules directly from BO LiveViews — use `NodeRouter.call/4`

---

## Dev Setup
```bash
mix setup && mix phx.server   # http://localhost:4000/bo
```