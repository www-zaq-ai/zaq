# ZAQ discovery map

- Single Elixir/OTP application, distributed by role; not an umbrella. Product/source orientation: [project](../../docs/project.md). Roles and cross-domain contracts: [architecture](../../docs/architecture.md).
- Startup and routing entry points: `lib/zaq/application.ex`, `node_roles.ex`, `node_router.ex`, `event.ex`. Storage is independently routable. Endpoint startup on a Channels node does not grant BO access.
- Cross-service convention is `NodeRouter.dispatch/1` with Events and supported domain actions, not generic invoke helpers. Existing legacy helpers do not override the [dispatch contract](../../docs/architecture.md#noderouter--critical).
- Repository docs own architecture/standards; memories support discovery. [Documentation hygiene](../../docs/documentation.md) owns placement and refresh rules; [docs index](../../docs/README.md) routes to owners. `AGENTS.md` is the coding-agent entry point.

## Focused notes
- Stack sources and dependency traps: `mem:tech_stack`.
- Command entry points and side effects: `mem:suggested_commands`.
- Boundary and testing pitfalls: `mem:conventions`.
- Validation/approval owner links: `mem:task_completion`.
- RAG, selection and Jido runtime: `mem:agent/core`.
- Incoming routing, workflows and watches: `mem:engine/core`.
- Bridges, records and Storage seams: `mem:channels/core`.
- Processing, search and materialization: `mem:ingestion/core`.
- BO layout, authorization and browser entry points: `mem:frontend/core`.
- Memory format and reference checks: `mem:memory_maintenance`.
