# ZAQ Project

## What is ZAQ

AI-powered company brain. Ingests documents, builds a knowledge base, answers questions
from humans and AI agents with cited responses. Deployed on-premise with a
customer-provided LLM endpoint.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Elixir 1.19 / Erlang OTP 28; exact development pins in [`.tool-versions`](../.tool-versions) |
| Web | Phoenix 1.8, LiveView 1.2; constraints in [`mix.exs`](../mix.exs), resolved dependencies in [`mix.lock`](../mix.lock) |
| Database | PostgreSQL 16+ with pgvector `>= 0.7.0` (`halfvec` support) |
| Jobs | Oban |
| Assets | Mix-managed esbuild/Tailwind; Node.js 20+ for Playwright |
| LLM | Customer-provided, configured per deployment |
| Agent/workflow runtime | Jido ecosystem and ReqLLM; dependency sources/overrides in `mix.exs` |

---

## Project Structure

```
lib/
├── zaq/
│   ├── accounts/         # Users, roles, auth
│   ├── agent/            # RAG, LLM, answering, retrieval
│   ├── channels/         # Communication/data-source bridges and provider integrations
│   ├── embedding/        # Embedding client (standalone)
│   ├── engine/           # Routing, conversations, workflows, watches and telemetry
│   ├── ingestion/        # Document processing, chunking, Oban jobs
│   ├── storage/          # Mounted-volume filesystem operations and access policy
│   ├── materialization/  # Trusted record-content handle redemption
│   ├── addons/           # Add-on package verification, feature gating
│   ├── node_router.ex    # Dispatches Events locally or remotely by role
│   └── application.ex   # Role-based OTP startup
├── zaq_web/
│   ├── live/bo/
│   │   ├── accounts/     # Users + Roles CRUD
│   │   ├── ai/           # Ingestion, Ontology, Prompt Templates, Diagnostics
│   │   ├── communication/# Channels, History, Chat, Conversations
│   │   ├── data_sources/ # Provider browsing and configuration
│   │   └── system/       # Password, add-ons
│   ├── controllers/
│   ├── plugs/auth.ex
│   └── router.ex
```

---

## Responsibilities and Navigation

[Architecture](architecture.md#service-responsibilities) owns the six node roles and
cross-service boundaries; not every source directory is an independently routable
service. For example, Accounts and the standalone Embedding client are domain
modules, not additional node roles.

Use the [domain guide index](README.md#domain-guides) for detailed contracts.
ExUnit tests mirror domains under `test/zaq/` and `test/zaq_web/`; shared fixtures
and fakes live in `test/support/`; browser journeys live in `test/e2e/`.

---

## Dev Setup

Follow [development setup](dev-setup.md) for setup, server, Python and browser-test
commands. Validation timing is owned by [the workflow](WORKFLOW_AGENT.md#phase-4--validate).
