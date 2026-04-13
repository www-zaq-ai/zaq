# Execution Plan: Jido Ingestion Pipeline

## Plan: Replace ingestion pipeline with Jido agent + Jido.Plan

**Date:** 2026-04-13
**Author:** Jad
**Status:** `completed`
**Related debt:** —
**PR(s):** —

---

## Goal

Replace the current ad-hoc ingestion pipeline — scattered across two Oban workers (`IngestWorker`, `IngestChunkWorker`), a Python pipeline runner, and manual `JobLifecycle` state tracking — with a single `Zaq.Ingestion.Agent` (`Jido.Agent`) that executes a `Zaq.Ingestion.Plan` (`Jido.Plan`). The plan defines five discrete actions: `UploadFile`, `ConvertToMarkdown`, `ChunkDocument`, `EmbedChunks`, `AddToRag`. Done means the full pipeline runs end-to-end through Jido, upload-only stops cleanly at `converted` status, and a previously converted file resumes from chunking without re-running conversion.

---

## Context

Docs to read before starting:

- [ ] `docs/architecture.md`
- [ ] `docs/conventions.md`
- [ ] `docs/services/ingestion.md`
- [ ] `priv/roadmap/jido-ingestion-pipeline.md`

Existing code relevant to this plan:

- `lib/zaq/ingestion/ingest_worker.ex` — current Oban orchestrator
- `lib/zaq/ingestion/ingest_chunk_worker.ex` — per-chunk Oban worker (to be deleted)
- `lib/zaq/ingestion/ingest_chunk_job.ex` — chunk job schema (to be deleted)
- `lib/zaq/ingestion/python/pipeline.ex` — Python step orchestration (stays, wrapped by action)
- `lib/zaq/ingestion/document_processor.ex` — chunking driver (stays, wrapped by action)
- `lib/zaq/ingestion/job_lifecycle.ex` — manual status transitions (to be replaced by Jido lifecycle)
- `lib/zaq/ingestion/ingest_job.ex` — Ecto schema, gains `converted` status
- `lib/zaq/ingestion/sidecar.ex` — sidecar `.md` path resolution (used in skip logic)

---

## Approach

Add Jido as a first-class dependency and model the ingestion pipeline as a `Jido.Plan` of five `Jido.Action` modules. Each action wraps existing logic (Python runner, DocumentChunker, embedding, RAG upsert) without rewriting it — the actions are thin adapters.

`IngestWorker` (Oban) is kept as a thin async entry point: it calls `Zaq.Ingestion.Agent.run/1` and nothing else. This preserves Oban's async queue, durable retries, and Oban Web visibility without duplicating orchestration logic.

`IngestChunkWorker` is deleted. Per-chunk Oban jobs were a workaround for the lack of plan-level checkpointing — Jido.Plan handles this natively.

Skip logic is expressed as plan-level conditions: if a `.md` sidecar already exists for the file, `UploadFile` and `ConvertToMarkdown` are skipped and the plan resumes from `ChunkDocument`. This avoids imperative branching inside actions.

**Why Jido over alternatives (plain GenServer, Broadway, Flow):**
- `Jido.Plan` gives us named, composable, independently testable steps
- Built-in skip/halt logic without custom state machines
- `jido_signal` gives us structured events for telemetry/LiveView updates with no extra wiring
- Aligns with the broader ZAQ agent architecture direction

---

## Steps

### Phase 1 — Dependencies & scaffolding

- [x] **Step 1:** Add `{:jido, "~> 2.2.0"}`, `{:jido_action, "~> 2.2.1"}`, `{:jido_signal, "~> 2.1.1"}` to `mix.exs`; `mix deps.get` done — note: package is `jido_action` (singular), `jido_signal` is `2.1.1`
- [x] **Step 2:** Add `converted` to `@statuses` in `IngestJob` — no DB migration needed (status is validated in Elixir only via `validate_inclusion`, no check constraint at DB level)
- [x] **Step 3:** Add `mark_converted!/1` to `JobLifecycle`

### Phase 2 — Action modules

- [x] **Step 4:** `Zaq.Ingestion.Actions.UploadFile` — validates file exists, resolves volume path, returns `%{file_path: resolved}`
- [x] **Step 5:** `Zaq.Ingestion.Actions.ConvertToMarkdown` — calls `DocumentProcessor.read_as_markdown/1` (now public); sidecar reused if already exists; returns `%{file_path, md_path, md_content, converted}`
- [x] **Step 6:** `Zaq.Ingestion.Actions.ChunkDocument` — delegates to `processor.prepare_file_chunks/1`; returns `%{document_id, indexed_payloads}`
- [x] **Step 7:** `Zaq.Ingestion.Actions.EmbedChunks` — clears old chunks, calls `store_chunk_with_metadata` concurrently per chunk; returns `%{document_id, results, ingested_count, failed_count}`
- [x] **Step 8:** `Zaq.Ingestion.Actions.AddToRag` — validates counts, emits telemetry; returns `%{ingested_count, failed_count}`

**Note:** `DocumentProcessor.read_as_markdown/1` was promoted from `defp` to `def` to allow `ConvertToMarkdown` to call it without duplicating conversion logic.

### Phase 3 — Plan & agent

- [x] **Step 9:** `Zaq.Ingestion.Plan` — `Jido.Plan` DAG via `Plan.build/0`; `Plan.chain/1` returns the action list for each mode (`:full`, `:upload_only`, `:from_converted`). Skip logic is mode selection, not plan conditions.
- [x] **Step 10:** `Zaq.Ingestion.Agent` — plain module (not `use Jido.Agent`); uses `Jido.Exec.Chain.chain/3` for sequential execution; updates `IngestJob` status at checkpoints (`processing` → `converted` | `completed` | `completed_with_errors` | `failed`)
- [ ] **Step 11:** Emit `jido_signal` events at each step transition for LiveView/telemetry consumption *(deferred — not blocking Phase 4)*

### Phase 4 — Wire up & clean out

- [x] **Step 12:** Slim `IngestWorker` to a single `Zaq.Ingestion.Agent.run(job)` call; remove all orchestration logic from the worker
- [x] **Step 13:** Delete `IngestChunkWorker` and `IngestChunkJob`; remove their Oban queue config
- [x] **Step 14:** ~~Add `Zaq.Ingestion.Agent` to `Zaq.Ingestion.Supervisor`~~ — not needed; Agent is a plain module, not a GenServer. `Jido.Action.TaskSupervisor` is started automatically by the `jido_action` OTP application.

### Phase 5 — Tests & cleanup

- [x] **Step 15:** Unit tests for each action module (happy path + error path)
- [x] **Step 16:** Integration test: full pipeline run end-to-end
- [x] **Step 17:** Integration test: upload-only run — stops at `converted`, no chunks created
- [x] **Step 18:** Integration test: resume-from-converted — skips upload/conversion, runs chunk→embed→rag
- [x] **Step 19:** `mix precommit` passes; update `docs/services/ingestion.md`

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Keep `IngestWorker` as thin Oban shell | Preserves async queue, durable retries, and Oban Web visibility without duplicating orchestration | 2026-04-13 |
| Delete `IngestChunkWorker` entirely | Per-chunk Oban jobs were a workaround for missing checkpointing — `Jido.Plan` handles this natively | 2026-04-13 |
| Skip logic via plan conditions, not action branching | Keeps actions composable and independently testable; skip state is plan-level concern | 2026-04-13 |
| Wrap existing Python pipeline, do not rewrite | Python conversion scripts are stable; actions are thin adapters to avoid scope creep | 2026-04-13 |
| `Zaq.Ingestion.Agent` is a plain module, not `use Jido.Agent` | `Jido.Agent` is a state-machine / command-bus pattern unsuited to DB-side-effect pipelines; plain module + `Exec.Chain` is the right tool | 2026-04-13 |
| Skip logic via mode selection, not plan conditions | `Jido.Plan` has no built-in `skip_if`; the Agent builds the right action list for each mode — cleaner and easier to test | 2026-04-13 |
| `Jido.Action.TaskSupervisor` not added to ZAQ supervisor | It is started automatically by the `jido_action` OTP application's `Application.start/2` callback | 2026-04-13 |
| No DB migration for `converted` status | Status validated in Elixir only (`validate_inclusion`); no check constraint exists at DB level | 2026-04-13 |
| `ChunkDocument` calls `prepare_file_chunks/1` (re-reads sidecar) | Avoids exposing private `extract_source/2` and `extract_sidecar_source/1`; sidecar already on disk so re-read is cheap | 2026-04-13 |
| `EmbedChunks` combines embed + DB insert | `store_chunk_with_metadata` does both atomically; splitting would require refactoring out of Phase 2 scope — `AddToRag` is a named hook for future extension | 2026-04-13 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Verify `jido ~> 2.2.0` hex availability and `Jido.Plan` API shape before Step 9 | Jad | **resolved** — `Jido.Plan` uses DAG builder: `Plan.new() \|> Plan.add(:step, Action, depends_on: :prev)`. `Jido.Action` uses `use Jido.Action, name:, schema:` + `@impl true def run(params, context)`. `jido_action` is the package name (singular). |

---

## Definition of Done

- [x] All steps above completed
- [x] Tests written and passing (unit per action + 3 integration scenarios)
- [x] `mix precommit` passes
- [x] `docs/services/ingestion.md` updated to describe Jido-based pipeline
- [ ] `docs/QUALITY_SCORE.md` updated for ingestion domain
- [ ] Plan moved to `docs/exec-plans/completed/`
