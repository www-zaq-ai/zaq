# Agent source map

- Owner: [Agent service](../../../docs/services/agent.md), including harness-critical checks. Source root: `lib/zaq/agent/`.
- `api.ex` is the role entry point: run_pipeline selects default RAG (`pipeline.ex`) versus explicit configured agent (`executor.ex`). Both string/atom selection keys exist; don't lose workflow-selected agents during normalization.
- Pipeline coordinates retrieval/extraction/answering/safety. Executor coordinates run scope and lifecycle; Factory/ProviderSpec build runtime/provider configuration; ServerManager owns Jido processes. Keep those responsibilities separate.
- Server identity includes request scope, not only configured-agent id. Check the service guide and RuntimeSync/ServerManager before changing hot-patch, restart or idle behavior.
- `tools/registry.ex` allowlists agent tools; `skills/`, `mcp/`, `context_window/` and `request_registry.ex` own distinct capability/state concerns. None bypasses trusted identity or permission checks.
- Routing policy comes from Engine (`mem:engine/core`), transport from Channels (`mem:channels/core`), document search from Ingestion (`mem:ingestion/core`).
