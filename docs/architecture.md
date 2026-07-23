# Architecture

## Overview

ZAQ is a single Elixir/OTP application composed of five internal services. Each service
runs under its own supervision tree and can be enabled or disabled per node using
role-based configuration.

```
┌──────────────────────────────────────────────────┐
│                    ZAQ (BEAM)                    │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │  Engine  │  │  Agent   │  │  Ingestion    │  │
│  │          │  │          │  │               │  │
│  │ Sessions │  │ RAG      │  │ Doc processing│  │
│  │ Notifs   │  │ LLM      │  │ Chunking      │  │
│  │ Telemetry│  │ Pipeline │  │ Embeddings    │  │
│  └──────────┘  └──────────┘  └───────────────┘  │
│                                                  │
│  ┌──────────┐  ┌──────────────────────────────┐  │
│  │ Channels │  │  Back Office (LiveView)      │  │
│  │          │  │                              │  │
│  │Mattermost│  │ Admin panel                  │  │
│  │ Slack *  │  │ Document management          │  │
│  │ Email *  │  │ Telemetry dashboards         │  │
│  └──────────┘  └──────────────────────────────┘  │
│  * planned                                       │
└──────────────────────────────────────────────────┘
```

---

## Multi-Node Roles

Services start based on `:roles` config or `ROLES` env var (`ROLES` takes priority).

| Role | Starts |
|---|---|
| `:all` | All services (default) |
| `:engine` | `Zaq.Engine.Supervisor` |
| `:agent` | `Zaq.Agent.Supervisor` |
| `:ingestion` | `Zaq.Ingestion.Supervisor` |
| `:channels` | `Zaq.Channels.Supervisor` |
| `:bo` | `ZaqWeb.Endpoint` |

Peer connectivity is automatic via Erlang distribution + EPMD peer discovery.
`Zaq.PeerConnector` handles automatic node connection — no `NODES` env var required.

---

## NodeRouter — CRITICAL

All cross-service calls from BO go through `Zaq.NodeRouter`, not direct module calls.

```elixir
# WRONG — breaks multi-node
Zaq.Agent.Retrieval.ask(question, opts)

# CORRECT
event = Zaq.Event.new(%{question: question, opts: opts}, :agent, opts: [action: :ask])
NodeRouter.dispatch(event).response
```

`NodeRouter.dispatch/1` is the preferred API. It routes a `%Zaq.Event{}` by
`event.next_hop.destination`, checks locally first, then performs remote dispatch on peer nodes.

Event envelope fields:
- `request`
- `assigns`
- `response`
- `hops`
- `next_hop` (`Zaq.EventHop`)
- `trace_id`
- `opts`
- `version`
- `actor`

### Dispatch Semantics (sync, async, multi-hop)

`NodeRouter.dispatch/1` is event-first and hop-driven:

- The current `next_hop` is consumed, appended to `hops`, then cleared on the in-flight event.
- Target role is resolved from `next_hop.destination` using role -> supervisor lookup.
- The target role API (`Zaq.<Role>.Api.handle_event/3`) is invoked locally or via RPC.

Hop type controls response timing:

- `:sync` hop: `dispatch/1` waits for role API completion and returns the updated event.
- `:async` hop: `dispatch/1` starts background work and returns immediately with the event that was dispatched.

Multi-hop behavior is recursive:

- If role handling returns an event with a new `next_hop`, `NodeRouter` dispatches again.
- This supports chained cross-role flows (for example agent -> channels return hops) without callers coordinating per-hop RPC.

Dispatch note:

- New code should use `dispatch/1` + `%Zaq.Event{}` directly.

Role mapping:
- `:agent` → `Zaq.Agent.*`
- `:ingestion` → `Zaq.Ingestion.*`
- `:engine` → `Zaq.Engine.*`, `Zaq.Engine.Conversations.*`
- `:channels` → `Zaq.Channels.*`
- `:bo` → `Zaq.Bo.*`, `ZaqWeb.*`

---

## Service Responsibilities

| Service | Supervisor | Responsibility |
|---|---|---|
| `engine` | `Zaq.Engine.Supervisor` | Orchestration, conversations, notifications, telemetry, adapter lifecycle, data-source watch-channel runtime state |
| `agent` | `Zaq.Agent.Supervisor` | RAG pipeline, configured-agent runtime, LLM calls, query rewriting, answering, prompt security |
| `ingestion` | `Zaq.Ingestion.Supervisor` | Document processing, chunking, embedding, Oban jobs, Python pipeline, watched-record filtering/deletion |
| `channels` | `Zaq.Channels.Supervisor` | Channel configs, provider calls, webhook normalization, PendingQuestions, Mattermost adapter |
| `bo` | `ZaqWeb.Endpoint` | Back Office LiveView UI, API controllers |

---

## Engine Subsystems

Engine is the largest service. It owns several internal subsystems:

### Conversations (`lib/zaq/engine/conversations/`)
Persists every Q&A exchange as a structured Conversation with Messages.
All BO calls go through `NodeRouter.dispatch/1` with `%Zaq.Event{}`.

### Notifications (`lib/zaq/engine/notifications/`)
Email notifications, inline fallback delivery, notification logs.
- `Zaq.Engine.Notifications` — public context
- `Zaq.Engine.Notifications.NotificationLog` — persisted delivery log

### Telemetry (`lib/zaq/engine/telemetry/`)
Full telemetry subsystem with in-memory buffer, rollups, and benchmark connectors.
- `Zaq.Engine.Telemetry` — public API: `record/4`
- `Zaq.Engine.Telemetry.Buffer` — in-memory buffer with periodic flush
- `Zaq.Engine.Telemetry.Rollup` — aggregation logic
- `Zaq.Engine.Telemetry.Contracts.*` — typed payload contracts (scalar, series, category, etc.)
- `Zaq.Engine.Telemetry.Workers.*` — Oban workers: aggregate rollups, prune points, pull benchmarks, push rollups
- `Zaq.Engine.Telemetry.BenchmarkConnector` — HTTP connector for external benchmark data

### Data Sources (`lib/zaq/engine/data_sources/`)

Provider watch ownership is split intentionally:

- Channels owns provider-facing watch/list/stop calls and webhook normalization.
- Engine owns durable watch-channel rows, checkpoints, expiration, renewal, and runtime error state.
- Ingestion owns user-facing document watch state, changed-record filtering, and deletion of removed watched documents and sidecars.

Engine modules:

- `Zaq.Engine.DataSources` — provider watch-channel coordination and checkpoint advancement.
- `Zaq.Engine.DataSources.WatchChannel` — durable provider channel ids, resource ids, checkpoints, expiration, runtime status, and provider metadata.
- `Zaq.Engine.DataSources.WatchChannelRenewalWorker` — scheduled renewal before provider expiration.

### Adapter Lifecycle (`lib/zaq/engine/`)
- `Zaq.Engine.IngestionSupervisor` — loads ingestion configs from DB, starts adapters dynamically
- `Zaq.Engine.RetrievalSupervisor` — loads retrieval configs from DB, starts adapters dynamically
- `Zaq.Engine.AdapterSupervisor` — shared adapter supervision logic
- `Zaq.Engine.Router` — engine-level internal routing (distinct from `NodeRouter`)

---

## Agent Pipeline

The agent pipeline is coordinated through `Zaq.Agent.Pipeline`:

```
User question
  → PromptGuard.validate/1          ← blocks prompt injection (BO node)
  → NodeRouter.dispatch(%Zaq.Event{next_hop: %Zaq.EventHop{destination: :agent}})
      → Pipeline                    ← orchestrates retrieval + answering
          → Retrieval.ask/2         ← LLM rewrites question into search queries
          → DocumentProcessor       ← hybrid search, returns ranked chunks
          → Answering.ask/2         ← LLM formulates answer from context
  → PromptGuard.output_safe?/1      ← checks for system prompt leakage (BO node)
```

Key agent modules:
- `Zaq.Agent.Pipeline` — orchestrates the full RAG flow
- `Zaq.Agent.LLM` / <code>Zaq.Agent.LLMRunner</code> — centralized LLM config and execution
- `Zaq.Agent.History` — conversation history management
- <code>Zaq.Agent.CitationNormalizer</code> — normalizes citations in answers

Configured-agent execution path:
- BO chat always dispatches to agent role with `action: :run_pipeline`
- Optional explicit selection is carried in `event.assigns["agent_selection"]`
- On the agent node, `Zaq.Agent.Api` decides:
  - no selection -> `Zaq.Agent.Pipeline.run/2`
  - explicit selection -> `Zaq.Agent.Executor.run/2`
- `Zaq.Agent.Executor` routes to a deterministic `Jido.AgentServer` name derived from configured agent id

### Configured Agent Runtime Lifecycle

- `Zaq.Agent.ServerManager.sync_runtime/1` reconciles tracked servers against current configured-agent state.
- For structural runtime changes, reconciliation is **stop-only**: stale servers are terminated and removed from manager tracking, then recreated lazily on the next message (`ensure_server/2`).
- Runtime sync responses include `stopped_server_ids` so BO/API callers can surface operational impact.
- Hot runtime patching remains the preferred path for non-structural updates when a compatible runtime is already running.

Field behavior categories:

- **Hot patch only**: `job`, `enabled_tool_keys`, `enabled_mcp_endpoint_ids`
- **Stop now, recreate on next message**: `model`, `credential_id`, `strategy`, `advanced_options`, `idle_time_seconds`, `memory_context_max_size`
- **Routing-only flag (no runtime restart/patch by itself)**: `conversation_enabled`
- **Drain and stop**: `active = false`

---

## Ingestion Pipeline

### Elixir Pipeline
```
File → IngestWorker → DocumentProcessor → DocumentChunker → IngestChunkWorker
     → ChunkTitle (LLM) → EmbeddingClient → Chunk (PGVector)
```

### Python Pipeline (`lib/zaq/ingestion/python/`)
Handles non-markdown files before they enter the Elixir pipeline:

```
File (PDF/DOCX/XLSX/image)
  → Python Runner
      → pdf_to_md / docx_to_md / xlsx_to_md   ← convert to markdown
      → image_to_text                           ← generate image descriptions
      → inject_descriptions                     ← embed descriptions into markdown
      → image_dedup                             ← deduplicate images
      → clean_md                                ← normalize markdown
  → Elixir chunking pipeline
```

Python scripts fetched via `mix zaq.python.fetch`. Requires Python 3.10+ and `.venv`.

### Sidecar (`lib/zaq/ingestion/sidecar.ex`)
Manages the Python process lifecycle as an OTP-supervised sidecar.

---

## Hooks System (`lib/zaq/hooks/`)

A pluggable hook system for extending ZAQ behavior at runtime:
- `Zaq.Hooks` — public API
- `Zaq.Hooks.Registry` — ETS-backed hook registry
- `Zaq.Hooks.Handler` — hook execution
- `Zaq.Hooks.Supervisor` — supervises the registry

Used for add-on-driven feature extensions loaded at runtime via `PostLoader`.

---

## System Config (`lib/zaq/system/`)

Config is split into dedicated modules per concern — never read config keys directly:

| Module | Reads |
|---|---|
| `Zaq.System.LLMConfig` | LLM provider, endpoint, model, feature flags |
| `Zaq.System.EmbeddingConfig` | Embedding provider, model, dimension, chunk sizes |
| `Zaq.System.ImageToTextConfig` | Image-to-text provider, model |
| `Zaq.System.EmailConfig` | SMTP settings |
| `Zaq.System.IngestionConfig` | Ingestion volume paths |
| `Zaq.System.TelemetryConfig` | Telemetry settings |
| `Zaq.System.SecretConfig` | AES-256-GCM encryption key management |

Always use the dedicated accessor (`Zaq.System.get_llm_config/0`, etc.) — never query `system_configs` directly.

---

## Layered Domain Architecture

Each business domain is divided into a fixed set of layers with strictly validated
dependency directions. Code can only depend **forward**:

```
Types → Config → Repo → Service → Runtime → UI
```

Cross-cutting concerns (auth, connectors, telemetry, feature flags) enter through
a single explicit interface: **Providers**. Anything else is disallowed and enforced
mechanically via custom linters and structural tests.

### Layer responsibilities

| Layer | What goes here |
|---|---|
| `Types` | Ecto schemas, structs, type definitions |
| `Config` | Config readers, feature flags |
| `Repo` | Ecto queries, persistence, upserts |
| `Service` | Business logic, orchestration |
| `Runtime` | OTP processes, GenServers, supervisors |
| `UI` | LiveViews, components, templates |

---

## What NOT To Do

- Don't add adapters to `Zaq.Channels.Supervisor` — Engine manages adapter lifecycle
- Don't define behaviour contracts in `lib/zaq/channels/` — they belong in `lib/zaq/engine/`
- Don't assume Slack, Email, or ingestion adapters exist — only Mattermost is implemented
- Don't move `embedding/client.ex` under `agent/` without discussion
- Don't add BO routes without updating auth plug and router
- Don't hardcode LLM endpoints — customer-configured via BO system config
- Don't call Agent, Ingestion, Engine, or Channel modules directly from BO — always use `NodeRouter.dispatch/1` with `%Zaq.Event{}`
- Don't use `:httpoison`, `:tesla`, or `:httpc` — use `:req` (`Req`) for all HTTP requests
- Don't read system config keys directly — always use the dedicated `Zaq.System.*Config` accessors

---

## Service Deep-Dives

For detailed internals of each service, see `docs/services/`:

- `docs/services/agent.md`
- `docs/services/channels.md`
- `docs/services/ingestion.md`
- `docs/services/addons.md`
- `docs/services/system-config.md`
- `docs/services/telemetry.md`
- `docs/services/bo-auth.md`
