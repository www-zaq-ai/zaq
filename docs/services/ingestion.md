# Ingestion Service

## Overview

The Ingestion service processes documents into searchable, embeddable chunks stored
in PostgreSQL with PGVector. It supports async (Oban) and inline processing modes,
hybrid search (full-text + vector with RRF fusion), real-time job status via PubSub,
and a Python-based pre-processing pipeline for PDF, DOCX, XLSX, and image files.

---

## Pipeline Flow

```
File path
  → Zaq.Ingestion.ingest_file/5             ← creates IngestJob, queues Oban worker
  → IngestWorker.perform/1                  ← document-level orchestrator
      → [Python.Pipeline.run/1]             ← optional: PDF/DOCX/XLSX → clean Markdown
      → DocumentProcessor.prepare_file_chunks/3
          → File.read/1                     ← read file content
          → Document.upsert/1               ← upsert document record
          → DocumentChunker.parse_layout/2  ← detect sections (headings, tables, figures)
          → DocumentChunker.chunk_sections/1 ← split into token-bounded chunks
          → persist ingest_chunk_jobs rows  ← one persisted child job per chunk
      → enqueue IngestChunkWorker jobs      ← queue: :ingestion_chunks
  → IngestChunkWorker.perform/1             ← chunk-level processor
      → store_chunk_with_metadata/5         ← for each chunk:
          → ChunkTitle.ask/1                ← LLM generates descriptive title
          → EmbeddingClient.embed/1         ← generate vector embedding
          → Chunk.changeset + Repo.insert   ← store to DB with PGVector halfvec
      → updates parent IngestJob counters   ← ingested_chunks/total_chunks/failed_chunks
```

---

## Modules

### Public API (`Zaq.Ingestion`)

**Ingestion triggers**
- `ingest_file/3` — trigger ingestion for a single file (`:async` or `:inline` mode); accepts `path, mode \\ :async, volume_name \\ nil`
- `ingest_folder/3` — trigger ingestion for all files in a directory; accepts `path, mode \\ :async, volume_name \\ nil`

**Job queries**
- `list_jobs/1` — paginated job list with optional status filter
- `get_job/1` — fetch a single job by ID
- `retry_job/1` — re-queue a failed job
- `cancel_job/1` — cancel a pending job
- `subscribe/0` — subscribe to `"ingestion:jobs"` PubSub topic for real-time updates

**Filesystem operations**
- `list_volumes/0` — returns configured volumes map
- `list_entries/2` — list directory entries for a volume + path
- `create_directory/2` — create a directory in a volume
- `upload_file/3` — write file content into a volume
- `file_info/2` — stat a file in a volume
- `rename_entry/4` — rename/move a file within a volume (delegates to `RenameService`)
- `delete_path/4` — delete a file or directory and its DB records
- `delete_paths/3` — batch delete
- `directory_snapshot/3` — lists entries and combines with DB document/job state (delegates to `DirectorySnapshot.build/4`)

**Access control**
- `can_access_file?/2` — returns true if a user may access a file; super admins bypass all checks; files with no permissions record are public by default
- `list_document_permissions/1` — list all permissions for a document (preloads `:person`, `:team`)
- `list_person_permissions/1` — list all permissions for a person (preloads `:document`)
- `list_folder_permissions/2` — unique set of person/team permissions across all documents under a folder
- `set_document_permission/4` — upsert a permission record for `type \in [:person, :team]`
- `delete_document_permission/1` — remove a permission by ID

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
- Detects: ATX headings (`#`), bold headings (`**...**`), italic headings (`_..._`),
  tables (`|...|`), figures (`![...](...)`), vision image blocks (`> **[Image: ...]**`)
- Builds heading stack to track parent path for each section
- Chunks sections into 400–900 token pieces (configurable via `config :zaq, Zaq.Ingestion`)
- Large sections split by paragraphs, then sentences if needed
- Each chunk prepends its section heading for embedding context
- Token counts via `Zaq.Agent.TokenEstimator`

### Document Processor (`Zaq.Ingestion.DocumentProcessor`)
- `process_single_file/1` — full pipeline: read → upsert doc → chunk → embed → store
- `prepare_file_chunks/3` — parses document and returns persisted chunk payloads for child jobs
- `process_folder/1` — processes all `*.md` files in a directory
- `store_chunk_with_metadata/5` — generates LLM title, embeds, validates dimension, inserts
- `hybrid_search/2` — full-text + vector search with RRF fusion (Reciprocal Rank Fusion, k=60)
- `similarity_search/2` — vector-only search with configurable distance threshold
- `similarity_search_count/1` — count of unique chunks matching via hybrid union
- `query_extraction/1` — token-limited context builder for the answering agent (max 5,000 tokens)
- Current limitation: `prepare_file_chunks/3` materializes all chunk payloads in memory before persistence/scheduling

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
- `XlsxToMd` — converts XLSX to Markdown
- `ImageDedup` — removes duplicate extracted images
- `CleanMd` — post-processes raw Markdown output
- `ImageToText` — generates image descriptions via Scaleway Vision API
- `InjectDescriptions` — injects image descriptions into Markdown

### File Explorer (`Zaq.Ingestion.FileExplorer`)
- Multi-volume filesystem navigator
- `list_volumes/0` — returns configured volumes map
- `list/2`, `list/3` — list directory entries for a volume + path
- `file_info/2` — stat a file in a volume
- `delete/2`, `delete_directory/2` — remove files/directories from a volume
- `rename/3` — move/rename a file within a volume

### Source Path (`Zaq.Ingestion.SourcePath`)
- Shared helpers for converting between filesystem paths and document sources
- `build_source/2` — builds volume-prefixed source from volume name + relative path
- `split_source/3` — splits a source back into `{volume_name, relative_path}`
- `absolute_to_source/1` — converts absolute path to canonical document source
- `volume_root_for_absolute/1` — resolves the volume root containing an absolute path
- `remap_source/3` — remaps source preserving volume-prefix style
- `source_candidates/2` — returns both legacy and canonical source lookup candidates

### Sidecar (`Zaq.Ingestion.Sidecar`)
- Helpers for sidecar companion Markdown metadata (PDF → `.md` pairs)
- `sidecar_path_for/1` — returns expected `.md` path for a source file (`.pdf`, `.docx`, `.xlsx`, `.png`, `.jpg`)
- `sidecar_source/1`, `sidecar_metadata/1` — read/build sidecar source links
- `put_sidecar_source/2`, `put_source_document_source/2` — mutate metadata maps
- `retarget_relative_path/3` — follows sidecar path on source move/rename

### Delete Service (`Zaq.Ingestion.DeleteService`)
- `delete_path/4` — deletes a file or directory from a volume, also deletes associated `Document` records and sidecar files
- `delete_paths/3` — batch delete; auto-detects file vs. directory per entry

### Rename Service (`Zaq.Ingestion.RenameService`)
- `rename_entry/4` — renames a file within a volume; updates `Document.source` and sidecar metadata in a single Ecto.Multi transaction; rolls back filesystem renames on DB failure

### Directory Snapshot (`Zaq.Ingestion.DirectorySnapshot`)
- `build/4` — combines filesystem entries with DB document/job state for the file explorer LiveView
- Returns `%{entries: [...], ingestion_map: %{name => %{ingested_at, stale?, permissions_count, can_share?, job_status}}}`
- For directory entries the map value contains `%{type: :directory, total_size, file_count, ingested_count}`
- `ingestion_map` values for files now include `permissions_count` (integer, count of `Permission` rows) instead of role-based fields

### Schemas

**`Zaq.Ingestion.Document`**
- Fields: `source` (unique), `content`, `title`, `content_type`, `metadata`, `role_id`, `shared_role_ids`
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
│       └── xlsx_to_md.ex         # XLSX → Markdown conversion
├── chunk.ex                      # Ecto schema for chunks with PGVector halfvec embedding
├── delete_service.ex             # File + document deletion with sidecar handling
├── directory_snapshot.ex         # Combines FS entries with DB state for LiveView
├── document.ex                   # Ecto schema for ingested documents
├── document_chunker.ex           # Layout-aware Markdown → sections → chunks
├── document_processor.ex         # Full pipeline: read, chunk, embed, store, search
├── file_explorer.ex              # Multi-volume filesystem utilities
├── ingest_chunk_job.ex           # Ecto schema for persisted child chunk jobs
├── ingest_chunk_worker.ex        # Oban worker for chunk-level processing/retries
├── ingest_job.ex                 # Ecto schema for ingestion job tracking
├── ingest_worker.ex              # Oban worker for async job processing
├── ingestion.ex                  # Public API: trigger, query, retry, cancel, delete, rename, permissions
├── job_lifecycle.ex              # IngestJob state transitions + PubSub broadcast
├── oban_telemetry.ex             # Oban telemetry setup
├── permission.ex                 # Ecto schema for person/team document access permissions
├── rename_service.ex             # File rename with DB source update + rollback
├── sidecar.ex                    # Sidecar companion Markdown metadata helpers
├── source_path.ex                # Path ↔ document source normalization helpers
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

- `INGESTION_VOLUMES=documents`
- `INGESTION_VOLUMES_BASE=/zaq/volumes`
- `INGESTION_BASE_PATH=/zaq/volumes/documents`

When using the default bind mount (`./ingestion-volumes:/zaq/volumes`), ensure the host folder exists before startup.
If you use `./zaq-local.sh`, this folder is created automatically.

```bash
mkdir -p ingestion-volumes/documents
```

All variables above are optional overrides; only change them if your deployment uses a different filesystem layout.

---

## Key Design Decisions

- **HalfVector not Vector** — embeddings stored as `Pgvector.Ecto.HalfVector` (float16) to halve storage
- **RRF fusion** — combines full-text rank and vector rank without score normalization issues
- **Upsert on source** — re-ingesting the same file replaces content, old chunks are deleted first
- **ChunkTitle via LLM** — every chunk gets an LLM-generated title prepended to improve retrieval quality
- **Dimension validation** — embedding dimension is checked against `EmbeddingClient.dimension()` before insert
- **Python pre-processing pipeline** — non-Markdown files (PDF, DOCX, XLSX) are converted to Markdown by Python scripts before the Elixir chunking pipeline; image descriptions are injected via Scaleway Vision API when a key is configured
- **Sidecar Markdown pattern** — binary files (`.pdf`, `.docx`, etc.) store their converted `.md` as a linked sidecar document; renames/deletes cascade to the sidecar
- **Volume-prefixed sources** — document sources are prefixed with volume name (`"documents/path/to/file.md"`) in multi-volume mode for namespace isolation
- **JobLifecycle extracted** — all IngestJob state transitions go through `JobLifecycle` to ensure PubSub broadcast is never missed
- **HTML parsing not implemented** — `DocumentChunker.parse_layout/2` raises on `:html` format

---

## What's Left

### Should Do
- [ ] Support non-markdown file types (PDF, DOCX) natively via `DocumentProcessor.Behaviour` (Python pipeline is a bridge)
- [ ] Add chunk deduplication (same content, different source)
- [ ] Expose ingestion progress as percentage in `IngestJob`
- [ ] Batch/stream `prepare_file_chunks/3` payload persistence for very large documents

### Nice to Have
- [ ] Implement HTML parsing in `DocumentChunker`
- [ ] Batch embedding requests to reduce LLM roundtrips
- [ ] Ingestion webhooks for external notification on completion
