# ZAQ source map and invariants

- Single Elixir/OTP application for an on-premise company knowledge brain: document ingestion, cited answering, configured agents, communication/data-source integrations, workflow DAGs, Phoenix back office. Not an umbrella app.
- Policy entry point: `AGENTS.md`. Repository docs own standards; Beadwork owns durable plans/progress; GitHub owns issues/PRs. Memories are supporting navigation, not replacement policy.
- Startup/routing truth: `lib/zaq/application.ex`, `node_roles.ex`, `node_router.ex`, `event.ex`, `event_hop.ex`. Six routable roles: agent, engine, ingestion, storage, channels, bo; `:all` enables all. Endpoint starts for BO **or channels**. Common Repo/PubSub/Oban/hooks/add-on infrastructure sits outside role-specific supervisors.
- BO cross-service operations use role-specific Events helpers backed by `NodeRouter.dispatch/1` and `%Zaq.Event{}`. Role `Api` modules own boundary handling; router owns dispatch, not business logic. Sync/async hops and returned next hops support distributed chains.
- Domain roots: `lib/zaq/`; UI: `lib/zaq_web/`; config: `config/`; DB migrations: `priv/repo/migrations/`; tests: `test/zaq/`, `test/zaq_web/`, `test/support/`, `test/e2e/`.
- Nil identity never grants permission. Trusted actor context must stay separate from model/provider request parameters. Read `docs/services/system-config.md` before secret-related changes; dedicated config accessors and encrypted persistence are mandatory.
- `docs/project.md` and older architecture examples can lag source: current Mix uses Phoenix 1.8, storage is an independent role, and channels include multiple bridge families. Verify claims against current modules; do not repeat the older “only Mattermost exists” statement. For new invoke calls follow Events-helper policy in `docs/conventions.md` and `docs/WORKFLOW_AGENT.md`, not older inline-event examples.

## Discovery graph
- Runtime versions, dependencies and asset tooling: `mem:tech_stack`.
- Setup/server/test/asset commands and their side effects: `mem:suggested_commands`.
- Domain boundaries, API design, injection and Action reuse: `mem:conventions`.
- Issue validation, coverage, E2E approval and final delivery gates: `mem:task_completion`.
- Agent selection, RAG and Jido runtime responsibilities: `mem:agent/core`.
- Incoming routing, workflows and provider-watch ownership: `mem:engine/core`.
- Provider bridges, trusted records and mounted-storage boundary: `mem:channels/core`.
- Document processing, search and materialization separation: `mem:ingestion/core`.
- BO layout/design/authentication and browser-test entry points: `mem:frontend/core`.
- Memory style and reference maintenance: `mem:memory_maintenance`.
