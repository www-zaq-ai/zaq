# Engine orchestration map

- Source root `lib/zaq/engine/`; owners `docs/services/engine.md`, `docs/services/workflows.md`, `docs/services/telemetry.md`. Engine role Api is distinct from cross-role NodeRouter.
- `incoming_message_router.ex` applies Engine routing policy to Events from Channels: enrich possible person identity, resolve matching routing rule, return same Event with executable next-hop fields. Rules/context in incoming_message_routing.ex and incoming_message_routing_rule.ex. Keep provider-specific payload normalization in Channels.
- Canonical message contracts under `messages/`; persistent history context `conversations.ex` + `conversations/`. BO access is routed, not direct context calls.
- `workflows.ex` owns workflow management/run persistence. Its moduledoc explicitly puts permission checks on callers (`Zaq.Permissions.can?/4`); do not assume entering this context authorizes an operation.
- `workflows/`: DAGBuilder/Composition/Node, StepRunner and Steps, WorkflowRunAgent, triggers/cron, approvals, watcher/recovery. Preserve workflow lifecycle/audit instead of ad-hoc Action calls. Workflow Action contract and reuse discovery are in `docs/action-reuse.md`; agent tool membership does not establish workflow eligibility.
- `data_sources.ex` + `data_sources/` own durable provider-watch channels/checkpoints/renewal/runtime error state. Provider-facing watch/list/stop and webhook normalization belong to Channels; watched-record filtering/deletion belong to Ingestion. This three-way split is deliberate.
- Adapter runtime ownership: ingestion_supervisor.ex, retrieval_supervisor.ex, channel_adapter_loader.ex; do not move adapter lifecycle casually into generic Channels supervisor.
- Other owned contexts: notifications/, telemetry/, connect/, action_schedules/. Application prep_stop interrupts in-flight workflow runs only when the node has Engine role; a BO-only shutdown must not interrupt remote Engine work.
- Provider/Storage seam details: `mem:channels/core`; document processing: `mem:ingestion/core`; agent selection/runtime: `mem:agent/core`.
