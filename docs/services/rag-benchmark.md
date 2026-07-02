# RAG Benchmark (LiveRAG)

## Overview

The RAG benchmark measures ZAQ's retrieval + answering quality against the
[LiveRAG/Benchmark](https://huggingface.co/datasets/LiveRAG/Benchmark) dataset
(arXiv 2511.14531) — 895 English Q&A pairs, each with ground-truth answer, the
1–2 FineWeb source documents it was written from, and a set of `direct` / `useful`
/ `useless` answer claims.

It is an **integration test** that runs ZAQ's real pipeline against **real AI
credentials** (real embeddings + LLM via the ZAQ Router). It does not mock
anything: it ingests the corpus, asks questions through `Zaq.Agent.Pipeline.run/2`,
and scores the results.

The benchmark is the acceptance gate for RAG changes (reranker, BM25 language fix,
top-N cap, etc. — see `docs/exec-plans/review/rag_audit_findings.md`): capture a
baseline, then re-run after each change and diff.

---

## Components

| File | Responsibility |
| --- | --- |
| `lib/mix/tasks/zaq.bench.liverag.build.ex` | `mix zaq.bench.liverag.build` — downloads the Parquet (dev-only `:explorer` dep) and writes `questions.jsonl` + `docs.jsonl` |
| `priv/bench/liverag/` | Normalized data + per-run outputs (all gitignored, reproducible) |
| `test/support/liverag_bench.ex` | `Zaq.TestSupport.LiveRAGBench` — data loading, real-AI provisioning, scoring helpers (recall, claim-coverage judge) |
| `test/support/liverag_corpus.ex` | `Zaq.TestSupport.LiveRAGCorpus` — ingest-once corpus manager (reuse / restore / build), keyed by embedding model |
| `test/zaq/bench/liverag_test.exs` | `Zaq.Bench.LiveRAGTest` — the `:benchmark_liverag` integration test (setup, runner, report) |
| `test/zaq/bench/liverag_bench_test.exs` | Fast unit tests for the deterministic scoring helpers (runs in normal CI) |

---

## How to run

### 1. Build the dataset (once)

```sh
mix zaq.bench.liverag.build
```

Writes `priv/bench/liverag/{questions,docs}.jsonl` (895 questions, 970 unique docs).

### 2. Run the benchmark

The test is tagged `:benchmark_liverag` and **excluded by default** (see
`test/test_helper.exs`). It only runs when invoked explicitly, and **skips itself**
(green, no-op) when `BENCH_LIVERAG_ROUTER_KEY` is unset — so it never runs or
charges in normal CI.

```sh
BENCH_LIVERAG_ROUTER_KEY=sk-... \
BENCH_LIVERAG_LLM_MODEL=<chat-model-your-gateway-serves> \
BENCH_LIVERAG_LIMIT=20 \
mix test --only benchmark_liverag
```

### Environment variables

| Var | Required | Meaning |
| --- | --- | --- |
| `BENCH_LIVERAG_ROUTER_KEY` | yes | LiteLLM gateway API key. Provisions the "ZAQ Router" credential + LLM + embedding config via `Zaq.UserPortal.Provisioner.provision_with_key/1` (one key wires both). |
| `BENCH_LIVERAG_ROUTER_URL` | no | Gateway base URL. Default is the local dev gateway; prod is `https://llm.zaq.ai`. Set this if your key was issued by a different LiteLLM instance. |
| `BENCH_LIVERAG_LLM_MODEL` | no | Override the chat model used for query-rewrite, answering, and the judge. Defaults to `Zaq.Agent.ZAQRouter.default_chat_model/0`. Set it to a model your gateway actually serves. |
| `BENCH_LIVERAG_LIMIT` | no | Cap the number of **questions** asked. The corpus stays the full 970 docs, so retrieval is still a real haystack. Omit to ask all 895. |

> The embedding model is whatever the ZAQ Router provisions
> (`Zaq.Agent.ZAQRouter.default_embedding_model/0`, e.g. nemotron @ 2048 dims).
> The chunks table is resized to match automatically.

---

## Corpus reuse (ingest once)

Embedding 970 docs is the slow, expensive part. `LiveRAGCorpus.ensure_loaded!/3`
does it **once per embedding model** and resolves, in order:

1. **reuse** — the committed corpus in the test DB already matches the model → instant.
2. **restore** — a per-model dump exists at `priv/bench/liverag/corpus/<model@dim>.sql`
   → `psql` restore (fast). Best-effort; any failure falls back to rebuild.
3. **build** — neither → ingest all 970 docs (slow, one-time) + `pg_dump` for next time.

Switching embedding models selects a different dump (or builds a new one), leaving
old dumps intact. So:

- **First run for a model:** slow (`[liverag] building corpus i/970`).
- **Every run after:** fast (`[liverag] corpus reused`/`restored`).

Requires `pg_dump`/`psql` on PATH for the dump layer; without them it logs a warning
and relies on committed reuse (still works on the same machine).

### Why two-phase setup

The corpus is loaded on a **committed** connection (so it persists + can be dumped).
The question phase then runs on a **transactional shared** sandbox connection
(`{:shared, self()}`) so the pipeline's spawned/detached processes (parallel
BM25+vector search, telemetry, hooks, NodeRouter) can all see the data — otherwise
they raise `DBConnection.OwnershipError`. Shared mode requires a real sandbox
checkout (not `sandbox: false`), and the index DDL is plain `CREATE INDEX` (no
`CONCURRENTLY`), so the transactional sandbox is safe.

---

## Reading the results

Each run prints a table to **stderr** (visible despite `capture_log: true`):

```
┌─ LiveRAG Benchmark ─────────────────────────────
  Questions scored : 20 / 20  (errors: 0)
  No-answer        : 0

  RETRIEVAL
    Hit rate (≥1 supporting doc found) :  85.0%
    Mean recall                        :  78.0%

  ANSWER
    Mean claim coverage                :  56.1%

  BY DIFFICULTY        recall  claim-cov   n
  easy          ...
└─────────────────────────────────────────────────
```

| Metric | Meaning |
| --- | --- |
| **Errors** | Pipeline crashes. Must be `0` for the numbers to be trusted. |
| **Hit rate** | % of questions where retrieval surfaced ≥1 gold supporting doc. The headline retrieval number. |
| **Mean recall** | Avg fraction of supporting docs retrieved per question (a 2-doc question finding 1 = 0.5). |
| **Mean claim coverage** | LLM-judge: avg fraction of the answer's `direct`+`useful` claims entailed by ZAQ's answer. The answer-quality number. |
| **No-answer** | How often ZAQ abstained. |
| **By difficulty** | Same metrics split by the dataset's IRT difficulty (easy `< -1`, medium, hard `> 1`). |

> Retrieval scores are only meaningful against the **full** corpus. If you ever
> shrink the corpus to gold-only docs, hit rate is a meaningless ~100% (there are
> no distractors to confuse retrieval). The current design always loads all 970.

### Output files

Written to `priv/bench/liverag/results/<timestamp>`:

- `<timestamp>.jsonl` — summary line + one compact JSON object per question
  (answer, retrieved vs supporting doc-ids, recall, claim-coverage).
- `<timestamp>.errors.txt` — full error trail (type, question, message, stacktrace)
  for every failed question. Written only when there are errors.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Test passes instantly, logs "skipping real-credential benchmark" | `BENCH_LIVERAG_ROUTER_KEY` not set. Expected — it's the safe default. |
| `401 token_not_found_in_db` | Key/gateway mismatch. The key wasn't issued by the gateway at `BENCH_LIVERAG_ROUTER_URL`. Point the URL at the right LiteLLM instance. |
| Answers are `429 "No deployments available for <model>"` | The chat model isn't served (or is in cooldown) on your gateway. Set `BENCH_LIVERAG_LLM_MODEL` to one it serves. |
| `expected N dimensions, not M` on insert | Chunks table dimension ≠ embedding model dimension. The corpus manager resets the table on build; delete the stale corpus marker (`priv/bench/liverag/corpus/CURRENT`) to force a rebuild. |
| `DBConnection.OwnershipError ... mode :manual` | A pipeline process can't reach the test connection. Ensure the question phase uses shared mode (`Sandbox.checkout(Repo)` + `mode({:shared, self()})`), not `sandbox: false`. |
| "no progress, looks hung" | It's ingesting/answering silently. Progress prints to **stderr**; the first run builds the full corpus (slow, one-time). |

---

## Local-only TEMP changes

Some changes exist to run this on a local machine and **must be reverted before merge**:

- `config/test.exs` — `port: 5436` (local Postgres).
- `test/support/liverag_bench.ex` — `@default_router_url "http://localhost:4020"`
  (prod is `https://llm.zaq.ai`).

---

## Scope & limitations

- **English only.** LiveRAG cannot exercise the multilingual BM25 language bug
  (audit fix #2). A separate multilingual benchmark (MIRACL + MMTEB) is deferred —
  see `docs/exec-plans/active/2026-06-27-liverag-benchmark-harness.md`.
- **Runtime.** ~20s/question (query-rewrite + answer + judge LLM round-trips). The
  full 895 is multi-hour; use `BENCH_LIVERAG_LIMIT` for quick reads against the full
  corpus.
- **Faithful to production.** Ingestion embeds raw chunk content (no `chunk_title`
  enrichment), matching the current production pipeline (title generation was
  removed in commit `ed949b95`).
