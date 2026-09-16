# Engine source map

- Owners: [Engine](../../../docs/services/engine.md), [workflows](../../../docs/services/workflows.md), [telemetry](../../../docs/services/telemetry.md). Source root: `lib/zaq/engine/`.
- `incoming_message_router.ex` enriches identity and selects executable Event hops; it is routing policy, not NodeRouter's cross-node transport. `conversations.ex` owns persistent history; `messages/` contains canonical payloads.
- `workflows.ex` owns persistence/run management, but its context contract puts permission checks on callers. `workflows/step_runner.ex` owns step lifecycle; don't replace it with ad-hoc Action execution.
- Watch ownership is three-way: Engine durable channels/checkpoints/renewal, Channels provider operations/webhooks, Ingestion watched-record filtering/deletion. Avoid pulling provider logic into `data_sources.ex`.
- `supervisor.ex` owns Engine children; workflow interruption on application shutdown is gated to Engine nodes so BO shutdown cannot interrupt remote runs.
- Bridge/Storage boundary: `mem:channels/core`; record processing: `mem:ingestion/core`; agent runtime: `mem:agent/core`.
