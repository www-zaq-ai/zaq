# Channels and Storage source map

- Owners: [Channels](../../../docs/services/channels.md), [Storage architecture](../../../docs/architecture.md#storage-and-materialization), [materialization](../../../docs/services/materialization.md).
- `lib/zaq/channels/communication_bridge.ex` and `data_source_bridge.ex` are domain boundaries; concrete JidoChat/JidoConnect/Email/Web/Disk bridges own provider details. Discover enabled support from current implementation/configuration, not old provider lists.
- Data-source callbacks separate TrustedContext from provider business params. Signed Record mutations authorize at the boundary; model-controlled fields cannot supply authority.
- `disk_bridge.ex` dispatches to the Storage role; it must not read mounted files on the Channels node. `lib/zaq/storage.ex` owns bytes/filesystem policy, not provider Records.
- Disk identity is volume plus source-relative path, not documents.id. Listings return unmaterialized Records; trusted handle redemption returns bytes without a Storage -> Channels callback loop. Consumers must not inspect opaque handle payloads.
- Watch/runtime ownership: `mem:engine/core`; ingestion consumers: `mem:ingestion/core`.
