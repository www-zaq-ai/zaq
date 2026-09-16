# Ingestion source map

- Owner: [Ingestion](../../../docs/services/ingestion.md). Main context is `lib/zaq/ingestion/ingestion.ex`, not `lib/zaq/ingestion.ex`; role boundary is api.ex.
- IngestWorker/IngestChunkWorker coordinate document/chunk work. DocumentProcessor/DocumentChunker own processing; standalone `lib/zaq/embedding/client.ex` owns embedding calls. JobLifecycle centralizes transitions and broadcasts.
- DocumentProcessor hybrid search combines BM25/vector legs via reciprocal-rank fusion; FTSBackend resolves deployment capability. Don't treat ParadeDB availability as universal.
- `python/` coordinates conversion before Elixir chunking. Job-scoped converted Markdown is scratch output, not a separate document to index.
- RecordSource/ContentSource/DocumentAccess/ExternalPermissions separate provenance and access. Mounted bytes/volume mutations belong to Storage; provider calls to Channels; durable watch checkpoints to Engine.
- Temporary materialization and shared handle contracts: [materialization](../../../docs/services/materialization.md), `temporary_materialization_store.ex` and `lib/zaq/materialization.ex`.
- Provider/Storage seam: `mem:channels/core`; watch coordination: `mem:engine/core`; search consumers: `mem:agent/core`.
