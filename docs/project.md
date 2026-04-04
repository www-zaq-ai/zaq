# ZAQ Project

## What is ZAQ

AI-powered company brain. Ingests documents, builds a knowledge base, answers questions
from humans and AI agents with cited responses. Deployed on-premise with a
customer-provided LLM endpoint.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Elixir 1.19.5 / Erlang OTP 28 |
| Web | Phoenix 1.7, Phoenix LiveView |
| Database | PostgreSQL 16+ with pgvector |
| Jobs | Oban |
| Assets | Node.js 20+ |
| LLM | Customer-provided, configured per deployment |

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
│   ├── engine/           # Orchestrator — adapter contracts + supervisors + Conversations context
│   ├── ingestion/        # Document processing, chunking, Oban jobs
│   ├── license/          # License verification, feature gating
│   ├── node_router.ex    # Routes RPC calls by role
│   └── application.ex   # Role-based OTP startup
├── zaq_web/
│   ├── live/bo/
│   │   ├── accounts/     # Users + Roles CRUD
│   │   ├── ai/           # Ingestion, Ontology, Prompt Templates, Diagnostics
│   │   ├── communication/# Channels, History, Playground, Conversations
│   │   └── system/       # Password, License
│   ├── controllers/
│   ├── plugs/auth.ex
│   └── router.ex
```

---

## Service Responsibilities

| Service | Responsibility |
|---|---|
| `accounts` | Users, roles, authentication |
| `agent` | LLM calls, query rewriting, answering, prompt security |
| `channels` | Shared infra, channel configs, Mattermost adapter |
| `embedding` | Standalone embedding HTTP client |
| `engine` | Adapter contracts, supervisors, conversations |
| `ingestion` | Document processing, chunking, Oban jobs, hybrid search |
| `license` | License loading, BEAM decryption, feature gating |

For deep-dives into each service, see `docs/services/`.

---

## Dev Setup

```bash
mix setup && mix phx.server   # http://localhost:4000/bo
```

Default credentials on fresh database: `admin` / `admin` (forced password change on first login).