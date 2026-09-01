# Ingestion Service

## Overview

The Ingestion service processes documents into searchable, embeddable chunks stored
in PostgreSQL with PGVector. It supports async (Oban) and inline processing modes,
hybrid search (full-text + vector with RRF fusion), real-time job status via PubSub,
and a Python-based pre-processing pipeline for PDF, DOCX, PPTX, XLSX, CSV, and image files.

---

## Pipeline Flow

```
Canonical records (from any data-source bridge)
  → Zaq.Ingestion.ingest_records/2          ← creates one IngestJob per record, queues Oban worker
  → IngestWorker.perform/1                  ← document-level orchestrator
      → [Python.Pipeline.run/2]             ← optional: PDF → clean Markdown
      → [DocxToMd/PptxToMd/XlsxToMd]        ← optional: office docs → temporary Markdown
      → [CSV parsing / image-to-text]       ← optional: CSV/images → Markdown
      → DocumentProcessor.prepare_file_chunks/1
          → File.read/1                     ← read file content
          → Document.upsert/1               ← upsert document record
          → DocumentChunker.parse_layout/2  ← detect sections (headings, tables, figures)
          → DocumentChunker.chunk_sections/1 ← split into token-bounded chunks
          → persist ingest_chunk_jobs rows  ← one persisted child job per chunk
      → enqueue IngestChunkWorker jobs      ← queue: :ingestion_chunks
  → IngestChunkWorker.perform/1             ← chunk-level processor
      → store_chunk_with_metadata/3         ← for each chunk:
          → EmbeddingClient.embed/1         ← embed embedding_input (section-path context + verbatim content)
          → Chunk.changeset + Repo.insert   ← store to DB with PGVector halfvec
      → updates parent IngestJob counters   ← ingested_chunks/total_chunks/failed_chunks
```

---

## Modules

### Public API (`Zaq.Ingestion`)

**Ingestion triggers**
- `ingest_records/2` — the entry point; takes `%Zaq.Contracts.Record{}` values from any data-source bridge and a `%{mode: :async | :inline}` map, and answers `{:ok, jobs}` or `{:error, {:partial_failure, jobs, errors}}`
- `ingest_record/2` — one record; a file record becomes a job, a folder record is expanded through `RecordSource.list_children/1` and fanned back into `ingest_records/2`

**Job queries**
- `list_jobs/1` — paginated job list with optional status filter
- `get_job/1` — fetch a single job by ID
- `retry_job/1` — re-queue a failed job
- `cancel_job/1` — cancel a pending job
- `subscribe/0` — subscribe to `"ingestion:jobs"` PubSub topic for real-time updates

**Data-source record consumption**
- Ingestion consumes canonical `%Zaq.Contracts.Record{}` values from Channels bridges.
- Disk is treated like any other data source: `Zaq.Channels.DiskBridge` returns stable
  provider records and Storage-owned materialization handles.
- Ingestion identifies indexed records by the generic source convention
  `data_source/<provider>/<config>/<record-id>` and imports canonical record permissions
  into ordinary document permissions during ingestion.
- Mounted volumes, file paths, bytes, rename/delete, and live file metadata are Storage
  concerns, not Ingestion concerns.

**Content filter / source search**
- `list_document_sources/1` — builds @-mention source choices from configured connectors + indexed document sources; supports name search and folder browse semantics

**Watch state and provider deltas**
- `request_watch/1`, `clear_watch/1` — update user-facing document watch status for local or provider targets.
- `mark_watch_active/2`, `mark_watch_error/2` — called after provider watch setup succeeds or fails.
- `process_data_source_changes/1` — consumes metadata-only provider deltas from Engine, schedules watched changed records for async ingestion, and deletes removed watched records.
- `count_watched_provider_documents/2` — counts watched provider documents for a data-source config.
- `data_source_inherited_watch/3`, `data_source_record_watch_state/2`, `data_source_record_watch_active?/1` — shared BO/processing helpers for direct and inherited folder watch state.

**Access control**
- `can_access_file?/2` — returns true if a user may access a file; super admins bypass all checks; Everyone grants provide public access; documents with no permission rows are private (admin-only)
- `list_document_permissions/1` — list all permissions for a document (preloads `:person`, `:team`)
- `list_person_permissions/1` — list all permissions for a person (preloads `:document`)
- `list_folder_permissions/2` — unique set of person/team permissions across all documents under a folder
- `set_document_permission/4` — upsert a permission record for `type \in [:person, :team]`
- `delete_document_permission/1` — remove a permission by ID
- `list_documents_under_folder/2` — list docs under a folder path
- `delete_folder_target_permission/3` — remove one permission record when pruning folder-level grants

### NodeRouter Boundary (`Zaq.Ingestion.Api`)
- Ingestion role boundary used by `Zaq.NodeRouter.dispatch/1`
- Uses shared internal boundary handling (`Zaq.InternalBoundaries.default_handle_event/3`)

### Oban Worker (`Zaq.Ingestion.IngestWorker`)
- Queue: `:ingestion`, max 3 attempts, 5s × attempt backoff
- Unique jobs per args within 120s window (prevents duplicate ingestion)
- Job lifecycle: `pending → processing → completed | completed_with_errors | failed`
- Broadcasts `{:job_updated, job}` on every state transition via PubSub
- `DocumentProcessor` is injectable: `Application.get_env(:zaq, :document_processor)`

### Oban Worker (`Zaq.Ingestion.IngestChunkWorker`)
- Queue: `:ingestion_chunks`, max 5 attempts, unique per `{job_id, chunk_job_id}` args window
- Processes one persisted chunk payload per job (`ingest_chunk_jobs`)
- On success: marks chunk `completed` and recomputes parent `IngestJob` counters
- On failure: marks chunk `pending` for retry; on final attempt marks `failed_final`
- On rate limit (`429`): snoozes retry delay using headers (`retry-after`, `ratelimit-reset`, `x-ratelimit-reset`), defaults to 60s
- Parent job is terminal only when all chunk jobs are terminal:
  - `completed` when all chunks succeeded
  - `completed_with_errors` when at least one chunk is `failed_final`

### Job Lifecycle (`Zaq.Ingestion.JobLifecycle`)
- Internal helper for all `IngestJob` state transitions + PubSub broadcast
- `transition/2`, `transition!/2` — generic changeset-based update + broadcast
- `mark_processing!/1`, `mark_completed!/2`, `mark_failed/3`, `mark_failed!/3`, `mark_pending_retry!/2`
- Broadcasts `{:job_updated, job}` to `"ingestion:jobs"` on every transition

### Document Chunking (`Zaq.Ingestion.DocumentChunker`)
- Layout-aware, hierarchical section detection for Markdown
- Detects: ATX headings (`#`),
  tables (`|...|`), figures (`![...](...)`), vision image blocks (`> **[Image: ...]**`)
- Builds heading stack to track parent path for each section
- Chunks sections into 400–900 token pieces (configurable via `config :zaq, Zaq.Ingestion`)
- Large sections split by paragraphs, then sentences if needed
- Store-raw / embed-enriched split: `chunk.content` preserves source lines but may join
  packed sections with blank lines, strip page markers, or repeat a row-split table
  header; the transient `chunk.embedding_input` (section-path context prefix + content)
  is used for embedding only — never persisted, FTS-indexed, or shown to users
- Source locators are added during parsing: chunk metadata stores `start`/`end` as
  `P<page>|L<line>` strings so callers can trace chunks back to converter Markdown
- Token counts via `Zaq.Agent.TokenEstimator`

### Chunks (`Zaq.Ingestion.Chunk`)
- `list_by_page/2` returns every chunk in one document whose source locator range covers
  a page number; it extracts page bounds from metadata and is intended for scoped,
  per-document navigation rather than an index-optimized global page search

### Document Processor (`Zaq.Ingestion.DocumentProcessor`)
- `process_single_file/1` — full pipeline: read → upsert doc → chunk → embed → store
- `prepare_file_chunks/1` — parses document and returns persisted chunk payloads for child jobs
- Non-Markdown converters write temporary `.md` files next to job-scoped materialized inputs because the Python pipeline expects output paths; those files are scratch artifacts, not indexed documents.
- `process_folder/1` — processes supported files in a directory (`.md .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg`)
- `store_chunk_with_metadata/3` — embeds `embedding_input || content`, validates dimension, inserts verbatim `content`
- `hybrid_search/2` — full-text + vector search with RRF fusion (Reciprocal Rank Fusion, k=60); accepts optional `:source_filter` list of path prefixes — files matched by exact source, folders matched by `LIKE prefix/%`
- `similarity_search/2` — vector-only search with configurable distance threshold
- `similarity_search_count/1` — count of unique chunks matching via hybrid union
- `query_extraction/2` — token-limited context builder for the answering agent (max context window from `Zaq.System.get_llm_config/0`)
- Uses `LanguageDetector` to choose per-chunk text-search language config with confidence threshold fallback
- Current limitation: `prepare_file_chunks/1` materializes all chunk payloads in memory before persistence/scheduling
- External data-source records persist their signed `materialization_handle` when available.
  `RecordSource.materialize/1` redeems handles through `Zaq.Materialization`; records without
  handles are reissued from trusted provider/config/file attributes before download.

### Document Access (`Zaq.Ingestion.DocumentAccess`)
- Centralized permission-filtered queries for counts/listings and source-filter handling
- Permission model:
  - documents granted to the system Everyone team are accessible to all
  - documents with matching person/team permission rows are accessible to the matched person/team
  - documents with no permission rows are private — only `skip_permissions: true` (BO admin) can access them
  - `skip_permissions: true` bypasses all filtering for admin/internal callers
- Exposes `build_source_filter_condition/1` used for consistent folder/file filter semantics

### Content Source (`Zaq.Ingestion.ContentSource`)
- Struct representing a user-selected content filter applied to a chat message
- Fields: `:connector` (string, e.g. volume name), `:source_prefix` (path prefix used in DB query), `:label` (display name shown in UI), `:type` (`:connector | :folder | :file | :current_folder`)
- `from_source/1` — parses a `Document.source` string into a `ContentSource`; returns `nil` on invalid input
- Used by `ChatLive` to populate `Incoming.content_filter`; the value travels through Engine incoming routing into the agent pipeline and is forwarded to `DocumentProcessor.hybrid_search/2` as `:source_filter`

### Language Detector (`Zaq.Ingestion.LanguageDetector`)
- Wraps Lingua detection for chunk text-search language selection
- Falls back to `"simple"` when token-count is too small or confidence is below threshold

### Python Pipeline (`Zaq.Ingestion.Python.Pipeline`)
- Orchestrates PDF → clean Markdown conversion via individual Python step scripts
- Steps: `PdfToMd → ImageDedup → CleanMd → [ImageToText] → [InjectDescriptions]`
- Steps 4–5 (image-to-text + inject descriptions) are skipped when no Scaleway API key is configured
- PDFs with spaces in their filename are processed via a temporary symlink/copy alias
- On failure, debug images are moved to `<volume_base>/debugging/<pdf_name>/`
- `run/2` returns `{:ok, md_path} | {:error, reason}`

### Python Runner (`Zaq.Ingestion.Python.Runner`)
- Base wrapper for Python scripts in `priv/python/crawler-ingest/`
- `run/2` — resolves script path, selects `.venv/bin/python3` over system `python3`, calls `System.cmd/3`
- `scripts_dir/0` — returns absolute path to the scripts directory
- `python_executable/0` — returns venv python if available, else `"python3"`

### Python Step Modules (`Zaq.Ingestion.Python.Steps.*`)
- `PdfToMd` — converts PDF to Markdown with image extraction
- `DocxToMd` — converts DOCX to Markdown
- `PptxToMd` — converts PPTX to Markdown
- `XlsxToMd` — converts XLSX to Markdown
- `ImageDedup` — removes duplicate extracted images
- `CleanMd` — post-processes raw Markdown output
- `ImageToText` — generates image descriptions via Scaleway Vision API
- `InjectDescriptions` — injects image descriptions into Markdown

### Schemas

**`Zaq.Ingestion.Document`**
- Fields: `source` (unique), `content`, `title`, `content_type`, `metadata`, `tags`, `watch_status`, `watch_requested_at`, `watch_updated_at`, `watch_error`
- Watch statuses: `unwatched`, `pending`, `watched`, `error`.
- Watch fields are user-facing BO state only. Provider channel ids, resource ids, checkpoints, expiration, and runtime errors live in `Zaq.Engine.DataSources.WatchChannel`.
- External provider documents store provider parent ids in metadata so sparse delete/tombstone signals can still remove watched descendants.
- `upsert/1` — conflict on `source`, replaces content/title/metadata
- `get_by_source/1` — lookup by source string
- `delete/1` — deletes document and cascades to chunks
- Title auto-derived from filename if not provided

**`Zaq.Ingestion.Chunk`**
- Fields: `document_id`, `content`, `chunk_index`, `section_path`, `metadata`, `embedding`
- `embedding` stored as `Pgvector.Ecto.HalfVector`
- `delete_by_document/1` — clears all chunks before re-ingestion
- `put_embedding/2` — separate changeset step for async embedding writes

**`Zaq.Ingestion.IngestJob`**
- Fields: `file_path`, `status`, `mode`, `error`, `started_at`, `completed_at`, `chunks_count`, `total_chunks`, `ingested_chunks`, `failed_chunks`, `failed_chunk_indices`, `document_id`, `volume_name`
- Statuses: `pending | processing | completed | completed_with_errors | failed`
- Modes: `async | inline`
- Primary key: UUID (`:binary_id`)

**`Zaq.Ingestion.IngestChunkJob`**
- Fields: `ingest_job_id`, `document_id`, `chunk_index`, `chunk_payload`, `status`, `attempts`, `error`
- Statuses: `pending | processing | completed | failed_final`
- Purpose: persisted chunk-level retries and resumable ingestion after restarts

**`Zaq.Ingestion.Permission`**
- Schema: `document_permissions`
- Fields: `document_id`, `person_id`, `team_id`, `access_rights` (array of strings, default `["read"]`)
- Valid rights: `read`, `write`, `update`, `delete`
- Either `person_id` or `team_id` must be set (enforced by DB CHECK constraint and changeset validation)
- Unique partial indexes: `(document_id, person_id)` where person_id not null; `(document_id, team_id)` where team_id not null

### Embedding Client (`Zaq.Embedding.Client`)
- Standalone module (not under `agent/`) — used by both ingestion and search
- OpenAI-compatible `/embeddings` endpoint via `Req`
- Config: `endpoint`, `api_key`, `model`, `dimension`
- Default model: `bge-multilingual-gemma2`, default dimension: `3584`
- Mockable in tests via `req_options: [plug: {Req.Test, Zaq.Embedding.Client}]`

### Document Processor Behaviour (`Zaq.DocumentProcessorBehaviour`)
- Single callback: `process_single_file/1`
- Allows swapping processor implementations without touching `IngestWorker`

---

## Files

```
lib/zaq/ingestion/
├── api.ex                        # NodeRouter ingestion boundary handler
├── python/
│   ├── pipeline.ex               # PDF → clean Markdown orchestrator
│   ├── runner.ex                 # Base wrapper for Python script execution
│   └── steps/
│       ├── clean_md.ex           # Markdown post-processing step
│       ├── docx_to_md.ex         # DOCX → Markdown conversion
│       ├── image_dedup.ex        # Duplicate image removal
│       ├── image_to_text.ex      # Vision API image description
│       ├── inject_descriptions.ex # Inject image descriptions into Markdown
│       ├── pdf_to_md.ex          # PDF → Markdown with image extraction
│       ├── pptx_to_md.ex         # PPTX → Markdown conversion
│       └── xlsx_to_md.ex         # XLSX → Markdown conversion
├── chunk.ex                      # Ecto schema for chunks with PGVector halfvec embedding
├── document.ex                   # Ecto schema for ingested documents
├── document_access.ex            # Permission-filtered document query helpers
├── document_chunker.ex           # Layout-aware Markdown → sections → chunks
├── document_processor.ex         # Full pipeline: read, chunk, embed, store, search
├── folder_setting.ex             # Folder-level tag policy persistence
├── ingest_chunk_job.ex           # Ecto schema for persisted child chunk jobs
├── ingest_chunk_worker.ex        # Oban worker for chunk-level processing/retries
├── ingest_job.ex                 # Ecto schema for ingestion job tracking
├── ingest_worker.ex              # Oban worker for async job processing
├── ingestion.ex                  # Public API: trigger, query, retry, cancel, delete, rename, permissions
├── job_lifecycle.ex              # IngestJob state transitions + PubSub broadcast
├── language_detector.ex          # Lingua-based chunk language detection
├── oban_telemetry.ex             # Oban telemetry setup
├── temporary_materialization_store.ex # Job-scoped temporary provider download files
└── supervisor.ex                 # Starts Oban under the :ingestion role

lib/zaq/embedding/
└── client.ex                     # Generic OpenAI-compatible embedding HTTP client

lib/zaq/ingestion/
└── document_processor_behaviour.ex  # Behaviour contract (Zaq.DocumentProcessorBehaviour) for document processor implementations
```

---

## Configuration

```elixir
# chunk/retrieval runtime knobs still in app env
config :zaq, Zaq.Ingestion,
  hybrid_search_limit: 20

config :zaq, Oban,
  repo: Zaq.Repo,
  queues: [ingestion: 3, ingestion_chunks: 6]
```

Runtime env vars used in `config/runtime.exs`:

- `OBAN_INGESTION_CONCURRENCY` (default `3`) — number of document-level ingestion jobs processed in parallel.
- `OBAN_INGESTION_CHUNKS_CONCURRENCY` (default `6`) — number of chunk child-jobs processed in parallel.

Impact:

- Lower `OBAN_INGESTION_CHUNKS_CONCURRENCY` reduces concurrent embedding/title generation pressure on LLM endpoints and DB writes.
- Higher values improve throughput, but can increase rate-limits and downstream load.
- Setting it to `1` serializes chunk worker execution per node.

Back Office System Config (`/bo/system-config`) now owns model-related settings:

- Embedding provider/model/api/dimension and chunk sizing are loaded via
  `Zaq.System.get_embedding_config/0`
- Image-to-text config (Scaleway API key) loaded via `Zaq.System.get_image_to_text_config/0`
- Retrieval thresholds (`max_context_window`, `distance_threshold`) are loaded via
  `Zaq.System.get_llm_config/0`

### Docker storage defaults

For containerized runs, ZAQ defaults to:

- `STORAGE_VOLUMES=` (one-time import input for Disk data-source volume declarations)
- `STORAGE_VOLUMES_BASE=/zaq/volumes` (base path for imported Disk volume declarations)

When using the default bind mount (`./ingestion-volumes:/zaq/volumes`), ensure the host folder exists before startup.
If you use `./zaq-local.sh`, this folder is created automatically.

```bash
mkdir -p ingestion-volumes
```

Disk volumes are now edited in Back Office at Data Sources > Disk and stored in the normal `ChannelConfig` settings. `Zaq.Storage[:base_path]` remains environment-backed; every volume path is resolved relative to it, and deleting a volume declaration only makes that path inaccessible to ZAQ.

---

## Key Design Decisions

- **HalfVector not Vector** — embeddings stored as `Pgvector.Ecto.HalfVector` (float16) to halve storage
- **RRF fusion** — combines full-text rank and vector rank without score normalization issues
- **Upsert on source** — re-ingesting the same file replaces content, old chunks are deleted first
- **Store-raw / embed-enriched chunks** — stored `chunk.content` is always a byte-exact substring of the source document; retrieval context (the joined section path) is added only to the transient `embedding_input` sent to the embedding model
- **Dimension validation** — embedding dimension is checked against `EmbeddingClient.dimension()` before insert
- **Python pre-processing pipeline** — non-Markdown files are converted to Markdown before chunking; image descriptions are injected via Scaleway Vision API when a key is configured
- **Multi-format conversion path** — non-Markdown files (`PDF`, `DOCX`, `PPTX`, `XLSX`, `CSV`, images) are normalized to Markdown before chunking
- **Temporary converter Markdown** — binary files (`.pdf`, `.docx`, etc.) may produce temporary `.md` files beside job-scoped materialized inputs because Python converters expect an output path. These files are cleanup-scoped scratch artifacts, not linked `Document` rows.
- **Provider watch ownership split** — Ingestion owns user-facing `Document.watch_status`, direct/inherited watch decisions, changed-record filtering, and document deletion. Engine owns provider watch-channel runtime state. Channels owns provider calls and webhook normalization.
- **Provider delta processing** — changed provider records are re-ingested only when directly watched or inherited through a watched folder. Removed/tombstone records delete existing documents only when the same shared watch-state logic says the record is watched.
- **Data-source sources** — document sources use provider/config/record identity (`data_source/<provider>/<config>/<record-id>`) for namespace isolation.
- **JobLifecycle extracted** — all IngestJob state transitions go through `JobLifecycle` to ensure PubSub broadcast is never missed
- **Permissions centralized for search/listing** — `DocumentAccess` is the canonical query surface for permission-scoped document visibility
- **HTML parsing not implemented** — `DocumentChunker.parse_layout/2` raises on `:html` format
- **pg_search is provisioned by migration; runtime self-heal is a safety net** — extensions are per-database and version-managed, so the deterministic place to ensure `pg_search` is created and current is the migration flow (`20260622000000_ensure_pg_search_current`), which runs uniformly across dev, test, CI and prod (including the separate test database). It is guarded on `pg_available_extensions` (clean no-op on standard Postgres) and runs `CREATE EXTENSION` + `ALTER EXTENSION pg_search UPDATE`; if pg_search is present but not loadable it raises a WARNING rather than failing the deploy. This is what makes the fix reliable rather than dependent on app-boot side effects.
- **FTS backend detection is read-only; healing self-heal is a startup safety net** — `FTSBackend.detect_and_cache/0`/`impl/0` only probe (`paradedb.version_info()` callable + index/table state) and never run DDL, so they are safe on any node and inside any transaction. For already-running deployments that have not re-migrated, `FTSBackend.self_heal/0` runs once at startup (gated in `Zaq.Application` to the `:ingestion` role so nodes never race on the DDL) and converges the DB based on `pg_available_extensions`: `:uninstalled` → `CREATE EXTENSION pg_search` (custom-database installs where the binary is preloaded but the extension was never created); `:stale` → `ALTER EXTENSION pg_search UPDATE` (the DB's extension is older than the loaded library, e.g. after an image upgrade — the case that breaks `paradedb.version_info()` and `pg_dump`); `:current`/`:absent` → no-op. It also provisions the BM25 index on a pre-existing chunks table. All heal DDL is savepoint-protected and falls through to Native on failure. When detection still resolves to Native while pg_search is installed (the library isn't loaded via `shared_preload_libraries` — a server config + restart ZAQ can't perform), `warn_if_degraded/2` logs a loud, actionable warning. Surfacing that in the BO is tracked in `docs/exec-plans/issues/fts-degraded-health-indicator.md`.

## Testing and Property Invariants

Follow `docs/testing-approach.md` for ingestion changes. Add property tests when logic touches normalization, mapping, counters, filtering, or retry/state transitions.

Ingestion invariants that should be property-tested when affected:

- **Source identity** (`ExternalSource`): canonical data-source IDs remain stable under valid input transformations.
- **Temporary materialization cleanup** (`RecordSource`, `TemporaryMaterializationStore`, `IngestWorker`): every job-scoped temporary root returned in `cleanup_paths` is removed after processing.
- **Chunking bounds** (`DocumentChunker`): emitted chunks respect configured token bounds and preserve deterministic ordering/indexing.
- **Job counter/state consistency** (`IngestChunkWorker`, `JobLifecycle`): parent totals and terminal statuses remain coherent for any mix of completed/failed chunk states.
- **Permission safety defaults** (`Permission` and access checks): missing permission rows make files private by default — only Everyone, person, or team permission rows grant access.

If a change touches one of these areas and no property test is added, document the reason in the PR.

---

## What's Left

### Should Do
- [ ] Support non-markdown file types (PDF, DOCX) natively via `DocumentProcessor.Behaviour` (Python pipeline is a bridge)
- [ ] Add chunk deduplication (same content, different source)
- [ ] Expose ingestion progress as percentage in `IngestJob`
- [ ] Batch/stream `prepare_file_chunks/1` payload persistence for very large documents

### Nice to Have
- [ ] Implement HTML parsing in `DocumentChunker`
- [ ] Batch embedding requests to reduce LLM roundtrips
- [ ] Outbound ingestion-completion notifications for external systems
