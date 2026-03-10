# Ingestion Service

## Overview

The Ingestion service processes documents into searchable, embeddable chunks stored
in PostgreSQL with PGVector. It supports async (Oban) and inline processing modes,
hybrid search (full-text + vector with RRF fusion), and real-time job status via PubSub.

---

## Pipeline Flow

```
File path
  → Zaq.Ingestion.ingest_file/2         ← creates IngestJob, queues Oban worker
  → IngestWorker.perform/1              ← picks up job, calls DocumentProcessor
  → DocumentProcessor.process_single_file/1
      → File.read/1                     ← read file content
      → Document.upsert/1               ← upsert document record
      → Chunk.delete_by_document/1      ← clear old chunks
      → DocumentChunker.parse_layout/2  ← detect sections (headings, tables, figures)
      → DocumentChunker.chunk_sections/1 ← split into token-bounded chunks (400-900 tokens)
      → store_chunk_with_metadata/3     ← for each chunk:
          → ChunkTitle.ask/1            ← LLM generates descriptive title
          → EmbeddingClient.embed/1     ← generate vector embedding
          → Chunk.changeset + Repo.insert ← store to DB with PGVector halfvec
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
- Job lifecycle: `pending → processing → completed | failed`
- Broadcasts `{:job_updated, job}` on every state transition via PubSub
- `DocumentProcessor` is injectable: `Application.get_env(:zaq, :document_processor)`

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
- `process_folder/1` — processes all `*.md` files in a directory
- `store_chunk_with_metadata/3` — generates LLM title, embeds, validates dimension, inserts
- `hybrid_search/2` — full-text + vector search with RRF fusion (Reciprocal Rank Fusion, k=60)
- `similarity_search/2` — vector-only search with configurable distance threshold
- `similarity_search_count/1` — count of unique chunks matching via hybrid union
- `query_extraction/1` — token-limited context builder for the answering agent (max 5,000 tokens)

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
- Fields: `file_path`, `status`, `mode`, `error`, `started_at`, `completed_at`, `chunks_count`, `document_id`
- Statuses: `pending | processing | completed | failed`
- Modes: `async | inline`
- Primary key: UUID (`:binary_id`)

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
# config/runtime.exs
config :zaq, Zaq.Ingestion,
  chunk_min_tokens:    400,
  chunk_max_tokens:    900,
  max_context_window:  5_000,
  distance_threshold:  0.75,
  hybrid_search_limit: 20

config :zaq, Zaq.Embedding.Client,
  endpoint:  System.get_env("EMBEDDING_ENDPOINT", "http://localhost:11434/v1"),
  api_key:   System.get_env("EMBEDDING_API_KEY", ""),
  model:     System.get_env("EMBEDDING_MODEL", "bge-multilingual-gemma2"),
  dimension: String.to_integer(System.get_env("EMBEDDING_DIMENSION", "3584"))

config :zaq, Oban,
  repo: Zaq.Repo,
  queues: [ingestion: 10]
```

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

### Nice to Have
- [ ] Implement HTML parsing in `DocumentChunker`
- [ ] Batch embedding requests to reduce LLM roundtrips
- [ ] Ingestion webhooks for external notification on completion