# Ingestion Service

## Overview

The Ingestion service processes documents into searchable, embeddable chunks stored
in PostgreSQL with PGVector. It supports async (Oban) and inline processing modes,
hybrid search (full-text + vector with RRF fusion), and real-time job status via PubSub.

---

## Pipeline Flow

```
File path
  → Zaq.Ingestion.ingest_file/2             ← creates IngestJob, queues Oban worker
  → IngestWorker.perform/1                  ← document-level orchestrator
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

## What's Done

### Public API (`Zaq.Ingestion`)
- `ingest_file/2` — trigger ingestion for a single file (`:async` or `:inline` mode)
- `ingest_folder/2` — trigger ingestion for all files in a directory
- `list_jobs/1` — paginated job list with optional status filter
- `get_job/1` — fetch a single job by ID
- `retry_job/1` — re-queue a failed job
- `cancel_job/1` — cancel a pending job
- `subscribe/0` — subscribe to `"ingestion:jobs"` PubSub topic for real-time updates

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
- Current limitation: `prepare_file_chunks/3` materializes all chunk payloads in memory before persistence/scheduling.

### Schemas

**`Zaq.Ingestion.Document`**
- Fields: `source` (unique), `content`, `title`, `content_type`, `metadata`
- `upsert/1` — conflict on `source`, replaces content/title/metadata
- Title auto-derived from filename if not provided

**`Zaq.Ingestion.Chunk`**
- Fields: `document_id`, `content`, `chunk_index`, `section_path`, `metadata`, `embedding`
- `embedding` stored as `Pgvector.Ecto.HalfVector`
- `delete_by_document/1` — clears all chunks before re-ingestion
- `put_embedding/2` — separate changeset step for async embedding writes

**`Zaq.Ingestion.IngestJob`**
- Fields: `file_path`, `status`, `mode`, `error`, `started_at`, `completed_at`, `chunks_count`, `total_chunks`, `ingested_chunks`, `failed_chunks`, `failed_chunk_indices`, `document_id`
- Statuses: `pending | processing | completed | completed_with_errors | failed`
- Modes: `async | inline`
- Primary key: UUID (`:binary_id`)

**`Zaq.Ingestion.IngestChunkJob`**
- Fields: `ingest_job_id`, `document_id`, `chunk_index`, `chunk_payload`, `status`, `attempts`, `error`
- Statuses: `pending | processing | completed | failed_final`
- Purpose: persisted chunk-level retries and resumable ingestion after restarts

### Embedding Client (`Zaq.Embedding.Client`)
- Standalone module (not under `agent/`) — used by both ingestion and search
- OpenAI-compatible `/embeddings` endpoint via `Req`
- Config: `endpoint`, `api_key`, `model`, `dimension`
- Default model: `bge-multilingual-gemma2`, default dimension: `3584`
- Mockable in tests via `req_options: [plug: {Req.Test, Zaq.Embedding.Client}]`

### Document Processor Behaviour (`Zaq.DocumentProcessor.Behaviour`)
- Single callback: `process_single_file/1`
- Allows swapping processor implementations without touching `IngestWorker`

---

## Files

```
lib/zaq/ingestion/
├── chunk.ex              # Ecto schema for chunks with PGVector halfvec embedding
├── document.ex           # Ecto schema for ingested documents
├── document_chunker.ex   # Layout-aware Markdown → sections → chunks
├── document_processor.ex # Full pipeline: read, chunk, embed, store, search
├── file_explorer.ex      # File system utilities (list, resolve paths)
├── ingest_job.ex         # Ecto schema for ingestion job tracking
├── ingest_chunk_job.ex   # Ecto schema for persisted child chunk jobs
├── ingest_chunk_worker.ex # Oban worker for chunk-level processing/retries
├── ingest_worker.ex      # Oban worker for async job processing
├── ingestion.ex          # Public API: trigger, query, retry, cancel jobs
├── oban_telemetry.ex     # Oban telemetry setup
└── supervisor.ex         # Starts Oban under the :ingestion role

lib/zaq/embedding/
└── client.ex             # Generic OpenAI-compatible embedding HTTP client

lib/zaq/document_processor/
└── behaviour.ex          # Behaviour contract for document processor implementations
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
- **HTML parsing not implemented** — `DocumentChunker.parse_layout/2` raises on `:html` format

---

## What's Left

### Must Do
- [ ] Implement `FileExplorer` properly (currently referenced but not fully reviewed)

### Should Do
- [ ] Support non-markdown file types (PDF, DOCX) via `DocumentProcessor.Behaviour`
- [ ] Add chunk deduplication (same content, different source)
- [ ] Expose ingestion progress as percentage in `IngestJob`
- [ ] Batch/stream `prepare_file_chunks/3` payload persistence for very large documents

### Nice to Have
- [ ] Implement HTML parsing in `DocumentChunker`
- [ ] Batch embedding requests to reduce LLM roundtrips
- [ ] Ingestion webhooks for external notification on completion
