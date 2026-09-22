# Architecture

## Overview

ZAQ is a single Elixir/OTP application with six routable roles. Role-specific
supervisors and the web endpoint are enabled per node; shared infrastructure
(Repo, PubSub, Oban, hooks and add-ons) starts outside those role-specific trees.
The startup and dispatch maps live in `lib/zaq/application.ex`,
`lib/zaq/node_roles.ex` and `lib/zaq/node_router.ex`.

```
ZAQ (single OTP application, distributed by role)
  Engine     — routing, conversations, workflows, coordination
  Agent      — retrieval/answering and configured-agent execution
  Ingestion  — document processing, chunking and search
  Storage    — mounted-volume filesystem and access policy
  Channels   — provider bridges and transport normalization
  BO         — Phoenix/LiveView back office
        ↕ cross-role Events through NodeRouter.dispatch/1
```

---

## Multi-Node Roles

Services start based on `:roles` config or `ROLES` env var (`ROLES` takes priority).

| Role         | Starts                     |
| ------------ | -------------------------- |
| `:all`       | All services (default)     |
| `:engine`    | `Zaq.Engine.Supervisor`    |
| `:agent`     | `Zaq.Agent.Supervisor`     |
| `:ingestion` | `Zaq.Ingestion.Supervisor` |
| `:storage`   | `Zaq.Storage.Supervisor`   |
| `:channels`  | `Zaq.Channels.Supervisor`  |
| `:bo`        | `ZaqWeb.Endpoint`          |

The endpoint also starts on a channels node for provider HTTP callbacks. Router
role plugs keep BO routes restricted to BO nodes; endpoint presence alone is not
BO availability.

Peer connectivity is automatic via Erlang distribution + EPMD peer discovery.
`Zaq.PeerConnector` handles automatic node connection — no `NODES` env var required.

### Role configuration

The default is to run all services on one node:

```elixir
config :zaq, roles: [:all]

# Equivalent explicit list
config :zaq, roles: [:bo, :agent, :ingestion, :storage, :channels, :engine]

# Or a subset
config :zaq, roles: [:engine, :bo]
```

An environment override takes precedence:

```bash
ROLES=engine,agent mix phx.server
```

### Local multi-node example

For local EPMD discovery, use distinct short node names on the same host and the same Erlang cookie. The following is a development topology, not a production networking/security recipe:

```bash
# Terminal 1: Back Office and orchestration
ROLES=engine,bo iex --sname bo@localhost --cookie zaq_local_example -S mix phx.server

# Terminal 2: AI, document processing and mounted storage
ROLES=agent,ingestion,storage iex --sname ai@localhost --cookie zaq_local_example -S mix

# Terminal 3: communication (the channels endpoint needs a distinct HTTP port)
PORT=4001 ROLES=channels iex --sname channels@localhost --cookie zaq_local_example -S mix
```

Use a private cookie and trusted network for real deployments. Successful connections are logged by `PeerConnector`; cross-role calls are then routed through `NodeRouter`. Shared database/configuration and storage reachability remain deployment responsibilities.

---

## NodeRouter — CRITICAL

All cross-service calls from BO go through `Zaq.NodeRouter`, not direct module calls.
New code uses **`NodeRouter.dispatch/1` with `%Zaq.Event{}` and an explicit domain
action**, not generic invoke calls. Verify the action and request shape in the
destination role's `Api.handle_event/3` before dispatching.

Example: `incoming` is an already normalized `%Zaq.Engine.Messages.Incoming{}`;
`actor` is trusted caller context, not an identity taken from model/user parameters.

```elixir
# WRONG — breaks multi-node
Zaq.Agent.Retrieval.ask(question, opts)

# CORRECT — Engine applies incoming routing policy before the Agent hop
event =
  Zaq.Event.new(incoming, :engine,
    actor: actor,
    opts: [action: :route_incoming_message]
  )

Zaq.NodeRouter.dispatch(event).response
```

`NodeRouter.dispatch/1` is the preferred API. It routes a `%Zaq.Event{}` by
`event.next_hop.destination`, checks locally first, then performs remote dispatch on peer nodes.
Materialization handles do not target exact nodes; their trusted handlers build fixed events
for the owning role, and `NodeRouter` routes to any node running that role.

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
- `name`

Trusted `event.opts[:confidential] == true` suppresses the entire envelope from
NodeRouter observer/workflow-trigger broadcasts, including `fire/1`. Dispatch and
remote hop execution still occur. Async failure diagnostics omit request fields
and replace error reasons with a fixed label. The flag is server-owned and must
be propagated to separately built child events; request payload fields cannot
opt out of observation. People bearer operations and OTP delivery events use it.

Trusted `event.opts[:confidential] == true` suppresses the entire envelope from
NodeRouter observer/workflow-trigger broadcasts, including `fire/1`. Dispatch and
remote hop execution still occur. Async failure diagnostics omit request fields
and replace error reasons with a fixed label. The flag is server-owned and must
be propagated to separately built child events; request payload fields cannot
opt out of observation. People bearer operations and OTP delivery events use it.

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

- Construct an Event with the destination's supported domain action in `event.opts`;
  dispatch it and consume the returned Event's `response` according to that action's contract.
- Preserve trusted actor context and runtime dependency overrides across hops.
  Dispatch is not an authorization grant; nil identity is never implicit permission.
- Generic `:invoke` handlers and `build_*invoke_event` helpers remain in legacy
  source. Their existence does not make them the convention for new calls. Do not
  disguise generic module/function/args invocation as an action-specific migration.
- Existing domain event builders can encapsulate a fixed request contract, but a
  helper is not mandatory merely because it exists. Direct Event construction and
  `dispatch/1` are supported. Missing domain actions require an explicit boundary
  design, not an invented action name or an automatic generic-invoke fallback.

Role mapping:

- `:agent` → `Zaq.Agent.*`
- `:ingestion` → `Zaq.Ingestion.*`
- `:storage` → `Zaq.Storage.*`
- `:engine` → `Zaq.Engine.*`, `Zaq.Engine.Conversations.*`
- `:channels` → `Zaq.Channels.*`
- `:bo` → `Zaq.Bo.*`, `ZaqWeb.*`

---

## Service Responsibilities

| Service     | Supervisor                 | Responsibility                                                                                                     |
| ----------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `engine`    | `Zaq.Engine.Supervisor`    | Orchestration, conversations, notifications, telemetry, adapter lifecycle, data-source watch-channel runtime state |
| `agent`     | `Zaq.Agent.Supervisor`     | RAG pipeline, configured-agent runtime, LLM calls, query rewriting, answering, prompt security                     |
| `ingestion` | `Zaq.Ingestion.Supervisor` | Document processing, chunking, embedding, Oban jobs, Python pipeline, watched-record filtering/deletion            |
| `storage`   | `Zaq.Storage.Supervisor`   | Mounted files, directory metadata, volume mutations and source-scoped access policy                                |
| `channels`  | `Zaq.Channels.Supervisor`  | Communication/data-source bridges, provider calls, transport normalization and webhook handling                    |
| `bo`        | `ZaqWeb.Endpoint`          | Back Office LiveView UI, API controllers                                                                           |

---

## Engine Subsystems

People authentication rate ownership is split: Engine supervises OTP Person/IP
issuance counters and owns persisted challenge verification attempts; Channels
supervises only unsuccessful-identification IP counters. Shared Hammer ETS/PubSub
mechanics have distinct role-local tables, listeners and replication topics.
Channels prechecks use a bounded, background-refreshed typed config snapshot with
no request-time database or Engine call. Public login uses one confidential Engine
resolve/issue/notify request after that precheck;
see [People authentication](services/people-access.md#rate-topology-and-retry-behavior).

`Zaq.Channels.Supervisor` is a static `:one_for_one` parent: it starts
`Zaq.Channels.PeopleAuthRateLimiter` first, then the dynamic
`Zaq.Channels.BridgeSupervisor`. The children restart independently. The parent
retains the Channels role-discovery name and delegates the existing runtime API;
the dynamic child reloads enabled bridge configs on every startup.

Engine is the largest service. It owns several internal subsystems:

### Connect mutation delivery (`lib/zaq/engine/connect/`)

OAuth callback/provider requests use the existing NodeRouter path with trusted
`opts: [confidential: true]`. These synchronous hops are routed normally but excluded
from the workflow trigger broadcast because they carry state, codes or client secrets.
The flag does not authenticate callers; ordinary mutation notifications below remain
observable and secret-free. Person OAuth starts remain backend-only; the existing
callback resolves identity from one-use persisted attempts, never browser owner IDs.

Connect writes enqueue versioned, secret-free identity notifications in the same Repo
transaction as credential/grant mutations. `MutationEventWorker` targets the Agent role
through the synchronous Agent Events helper and NodeRouter; only explicit `response: :ok`
completes delivery. NodeRouter's workflow stream receives the same allowlisted payload.
Connect does not publish directly to PubSub or call ServerManager.

The dedicated `connect_credential_notifications` queue is deliberately unconsumed in
every dev/production role configuration until a real Agent receiver and owning-node
fanout ship. Writes still enqueue while consumption is disabled. Three-attempt Oban
retry retains a UUID; timestamps do not impose ordering and no monotonic revision is
invented. Delivery may duplicate/reorder and does not acknowledge downstream consumers
or guarantee all-node fanout. Later integration must re-read current state, reconcile
missed events and close creation/invalidation races before activating consumption.
Activation also requires an explicit retention/replay and discarded-job policy; no
silent pruning of old dead jobs. See `docs/services/engine.md` for the full event schema.

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
- Ingestion owns user-facing document watch state, changed-record filtering, and deletion of removed watched documents.

Engine modules:

- `Zaq.Engine.DataSources` — provider watch-channel coordination and checkpoint advancement.
- `Zaq.Engine.DataSources.WatchChannel` — durable provider channel ids, resource ids, checkpoints, expiration, runtime status, and provider metadata.
- `Zaq.Engine.DataSources.WatchChannelRenewalWorker` — scheduled renewal before provider expiration.

### Adapter Lifecycle (`lib/zaq/engine/`)

- `Zaq.Engine.IngestionSupervisor` — loads ingestion configs from DB, starts adapters dynamically
- `Zaq.Engine.RetrievalSupervisor` — loads retrieval configs from DB, starts adapters dynamically
- `Zaq.Engine.ChannelAdapterLoader` — shared configuration-to-child loading
- `Zaq.Engine.IncomingMessageRouter` — incoming routing policy (distinct from cross-role `NodeRouter`)

Workflow DAGs, triggers, approvals and recovery are also Engine-owned; see
[workflows](services/workflows.md). The Engine supervisor includes workflow run
registration/recovery and the event registry, in addition to telemetry and adapters.

---

## Agent Pipeline

The agent pipeline is coordinated through `Zaq.Agent.Pipeline`:

```
Normalized Incoming + trusted actor
  → Engine :route_incoming_message  ← identity enrichment and routing policy
  → Agent :run_pipeline             ← role API validates input and selects execution path
      → Pipeline (default RAG)      ← retrieve → extract → answer → output safety check
      → Executor (selected agent)   ← configured-agent execution
```

Key agent modules:

- `Zaq.Agent.Pipeline` — orchestrates the full RAG flow
- `Zaq.Agent.ProviderSpec` / `Zaq.Agent.Factory` — provider normalization and runtime/model configuration
- `Zaq.Agent.Executor` / `Zaq.Agent.ServerManager` — run lifecycle and Jido server management
- `Zaq.Agent.History` — conversation history management
- <code>Zaq.Agent.CitationNormalizer</code> — normalizes citations in answers

Configured-agent execution path:

- BO chat dispatches `%Incoming{provider: :web}` to Engine with `action: :route_incoming_message`
- Optional explicit BO selection is carried in `event.assigns["agent_selection"]` with `source: "bo_explicit"`
- Engine incoming routing turns the request into the executable agent `:run_pipeline` hop
- On the agent node, `Zaq.Agent.Api` decides:
  - no selection -> `Zaq.Agent.Pipeline.run/2`
  - explicit selection -> `Zaq.Agent.Executor.run/2`
- `Zaq.Agent.Executor` derives conversation/person/session/anonymous scope and asks `ServerManager` for the matching Jido runtime; server identity is not just a configured-agent id

### Configured Agent Runtime Lifecycle

- `Zaq.Agent.ServerManager.sync_runtime/1` reconciles tracked servers against current configured-agent state.
- For structural runtime changes, reconciliation is **stop-only**: stale servers are terminated and removed from manager tracking, then recreated lazily on the next message (`ensure_server/4`).
- Server creation requires an explicit trusted execution actor, validated by `Zaq.Identity.ExecutionActor` before runtime configuration or lifecycle mutations. Scope determines isolation/reuse; it never establishes identity.
- Each live runtime retains its creation actor in `execution_actor`, independently of mutable request tool context. Warm reuse compares stable Person ID or explicit non-Person kind/subject; mismatches fail before touch, replacement or execution. Existing scope formats are unchanged, so sharing a scope across different identities now returns an error rather than rebinding the server.
- Missing or malformed actors fail closed. Trusted BO/channel/system origins establish non-Person identities explicitly; neither Executor nor ServerManager converts missing actors into system or anonymous principals. Credential grant selection remains separate work; there is no per-request credential resolution.
- Runtime sync responses include `stopped_server_ids` so BO/API callers can surface operational impact.
- Hot runtime patching remains the preferred path for non-structural updates when a compatible runtime is already running.

Field-level reconciliation and in-flight request behavior belong to the
[Agent service guide](services/agent.md) and `ServerManager`/`RuntimeSync`, rather
than a second field matrix in this overview.

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

Python converters may write temporary Markdown outputs next to job-scoped materialized inputs. These scratch files are deleted with the materialization root and are not indexed as separate documents.

### Storage and Materialization

`Zaq.Storage` owns mounted-volume bytes, directory metadata, mutations and access
policy. Ingestion consumes records; it does not own mounted filesystem operations.

`Zaq.Channels.DiskBridge` dispatches to Storage and maps filesystem entries/grants
into `Zaq.Contracts.Record`. Listings return metadata with `content: nil` and a
materialization handle, not file bytes. Disk identity is volume plus relative source
path, independent of whether a document has been ingested.

Handle redemption uses trusted materializers and the owning role. Storage returns
bytes rather than shaping provider Records or routing back through Channels.
See [materialization](services/materialization.md) for handle security/lifecycle and
[Channels](services/channels.md) for bridge contracts.

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

| Module                         | Reads                                             |
| ------------------------------ | ------------------------------------------------- |
| `Zaq.System.LLMConfig`         | LLM provider, endpoint, model, feature flags      |
| `Zaq.System.EmbeddingConfig`   | Embedding provider, model, dimension, chunk sizes |
| `Zaq.System.ImageToTextConfig` | Image-to-text provider, model                     |
| `Zaq.System.EmailConfig`       | SMTP settings                                     |
| `Zaq.System.IngestionConfig`   | Ingestion volume paths                            |
| `Zaq.System.TelemetryConfig`   | Telemetry settings                                |
| `Zaq.System.SecretConfig`      | AES-256-GCM encryption key management             |

Always use the dedicated accessor (`Zaq.System.get_llm_config/0`, etc.) — never query `system_configs` directly.

---

## Layered Domain Architecture

Separate the following responsibilities within each domain. These are design and
review constraints, not a claim that every domain uses identical directories or
that a universal structural linter enforces them. UI/runtime orchestration delegates
to domain contracts; provider and cross-role boundaries remain explicit. Follow
[conventions](conventions.md#context-boundaries) and the owning service guide for
allowed dependencies.

### Layer responsibilities

| Layer     | What goes here                          |
| --------- | --------------------------------------- |
| `Types`   | Ecto schemas, structs, type definitions |
| `Config`  | Config readers, feature flags           |
| `Repo`    | Ecto queries, persistence, upserts      |
| `Service` | Business logic, orchestration           |
| `Runtime` | OTP processes, GenServers, supervisors  |
| `UI`      | LiveViews, components, templates        |

---

## What NOT To Do

- Don't add adapters to `Zaq.Channels.Supervisor` — Engine manages adapter lifecycle
- Don't relocate contracts by a blanket namespace rule: Engine owns its orchestration/channel contracts; Channels owns `Bridge`, `CommunicationBridge` and `DataSourceBridge` contracts
- Don't infer provider support from an old diagram: inspect current bridge implementations/configuration and [Channels](services/channels.md)
- Don't move `embedding/client.ex` under `agent/` without discussion
- Don't add BO routes without updating auth plug and router
- Don't hardcode LLM endpoints — customer-configured via BO system config
- Don't call Agent, Ingestion, Engine, or Channel modules directly from BO — always use `NodeRouter.dispatch/1` with `%Zaq.Event{}`
- Don't use `:httpoison`, `:tesla`, or `:httpc` — use `:req` (`Req`) for all HTTP requests
- Don't read system config keys directly — always use the dedicated `Zaq.System.*Config` accessors

---

## Service Deep-Dives

Use the [domain guide index](README.md#domain-guides) for service contracts and
the [project map](project.md) for source navigation. Documentation ownership and
maintenance are defined in [documentation hygiene](documentation.md).
