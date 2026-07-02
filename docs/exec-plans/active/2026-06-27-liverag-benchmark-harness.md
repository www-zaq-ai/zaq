# Execution Plan: LiveRAG Benchmark Harness for ZAQ

**Date:** 2026-06-27
**Author:** Jad
**Status:** `active`
**Related debt:** RAG audit — `docs/exec-plans/review/rag_audit_findings.md`
**PR(s):** _tbd_

---

## Goal

Adopt the **LiveRAG/Benchmark** (HF: `LiveRAG/Benchmark`, arXiv 2511.14531) as ZAQ's
standing RAG quality benchmark **before** implementing any audit fix, so every
enhancement (reranker, top-N cap, vector-metric, etc.) is measured against a fixed
baseline. Done = a repeatable, low-cost harness that loads the benchmark questions
and their source docs into ZAQ, runs all 895 through ZAQ's real retrieval + answering
path, scores answer quality, and emits a versioned report we can diff per change.

---

## What we're actually using (simplified, decided scope)

The benchmark **is the 895 questions.** Each question ships with everything we need:

- `Question` — the question text
- `Answer` — the ground-truth answer
- `Supporting_Documents` — the **1–2 source documents the question was written from**
- `Answer_Claims` — `direct` / `useful` / `useless` claims, for scoring correctness
- difficulty calibration (`ACS`, `IRT-diff`, `IRT-disc`) for segmenting results

**Decision (corpus): closed per-question set.** We load only the documents that ship
with the 895 questions (~1,400 small docs total) into ZAQ — **not** the full
FineWeb-10BT 15M-document corpus. This is **<1 GB, runs locally in minutes, costs
near nothing.** The full-corpus ("15M-doc haystack") path is **dropped** — it cost
~$2–8k + days and added no value for our purpose.

**Decision (multilingual): English-first.** LiveRAG is English-only. Audit fix #2
(hardcoded `'english'` BM25, incl. the stored `to_tsvector('english', content)`
generated column in `fts_backend/native.ex`) **cannot be measured here** — verified by
code inspection now; measured multilingual eval **deferred to a separate plan**.
- Deferred candidate (recommended): **MIRACL** (18-language retrieval set with
  per-language relevance judgments — the right shape to measure the per-language
  `to_tsvector(<lang>)` fix) + **MMTEB / MTEB-multilingual** for the
  `bge-multilingual-gemma2` embedding layer. Fallbacks: MKQA, TyDi QA, NoMIRACL.

---

## Approach

All-Elixir harness, all local (no Python in the runtime path):
1. **`mix zaq.bench.liverag.build`** (Elixir) — downloads the Parquet (`Req`), reads it
   (`Explorer`, dev-only dep), and writes `questions.jsonl` + `docs.jsonl`.
2. **`mix zaq.bench.liverag`** (Elixir) — reads `questions.jsonl`, runs each through
   ZAQ's real `Zaq.Agent.Retrieval.ask/2` + answering path, writes a results JSONL
   (retrieved chunks + generated answer + no-answer signal).
3. **Scoring** (Elixir, reusing ZAQ's own LLM clients) — retrieval recall + RAGAS-style
   component metrics (faithfulness, context recall, answer correctness via **claim
   coverage** of direct/useful claims) via a pinned LLM judge; aggregate report overall
   + by `IRT-diff` difficulty bucket and `answer-type-categorization`.

Baseline is captured once on `main`; each audit fix re-runs and diffs against it.

---

## Steps

- [x] **Step 1 — Data acquisition & normalization.** `mix zaq.bench.liverag.build`
  downloads the Parquet and writes `questions.jsonl` (895) + `docs.jsonl` (970 unique
  source docs) under `priv/bench/liverag/`. Output verified byte-identical to the
  earlier reference. Data is gitignored/derived; only the task + README are tracked.
- [~] **Step 2 — Load the source docs into ZAQ (tagged integration test).** Folded into
  the end-to-end test (`test/zaq/bench/liverag_test.exs`), `@moduletag :benchmark_liverag`
  (excluded by default; run with `mix test --only benchmark_liverag`). Runs in **test env
  against REAL AI** provisioned via the **ZAQ Router** path
  (`Provisioner.provision_with_key/1`) from `BENCH_LIVERAG_ROUTER_KEY` — one key wires LLM
  + embedding; `Req.Test` embedding stub bypassed (`test/support/liverag_bench.ex`). Loads
  970 docs via real `store_document/3` + `process_and_store_chunks/2`. **Skips cleanly**
  without key/data. Embeds raw chunk content (no `chunk_title`) — **faithful to production**
  (title gen removed in `ed949b95`).
- [~] **Step 3 — Benchmark runner.** In the same test: builds `%Incoming{}` per question,
  drives the **real** `Zaq.Agent.Pipeline.run/2` (admin scope via `skip_permissions: true`),
  captures answer + retrieved sources (`metadata[:sources]` → doc_ids). `BENCH_LIVERAG_LIMIT`
  caps the subset for smoke runs. Writes a timestamped results JSONL under
  `priv/bench/liverag/results/` (gitignored).
- [~] **Step 4 — Scoring & report.** `LiveRAGBench`: retrieval **recall** vs
  `supporting_doc_ids` (deterministic, unit-tested) + answer **claim coverage**
  (direct/useful) via an LLM judge through the configured ZAQ Router model; summary
  (mean recall, mean claim coverage, no-answer/error counts) written atop the results file.
  - Status: code complete; deterministic scoring unit-tested (`liverag_bench_test.exs`,
    8/8). LLM-judge + full pipeline run pending a real `BENCH_LIVERAG_ROUTER_KEY`.
    TODO: difficulty-bucket segmentation (by `irt_diff`) + judgment caching.
- [ ] **Step 5 — Baseline + regression gate.** Run end-to-end on `main`, commit the
  baseline report, and document the "re-run + diff" loop each audit fix must pass
  before merge. Wire into the RAG-fix plans as their acceptance gate.

---

## Decisions Log

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Use the closed per-question doc set (~1,400 docs), **drop full FineWeb-10BT** | Each question ships with its source docs; the 15M-doc haystack cost ~$2–8k + days with no value for our goal | 2026-06-27 |
| English-first; LiveRAG-only. Multilingual fix verified by inspection, measured eval deferred | LiveRAG is English-only and cannot exercise the per-language BM25 bug | 2026-06-27 |
| Multilingual candidate (later) = MIRACL + MMTEB | Audit #2 is a per-language BM25 stemming bug → needs a retrieval set with per-language relevance, not a QA set | 2026-06-27 |

---

## Definition of Done

- [ ] All steps completed
- [ ] `mix zaq.bench.liverag` runs all 895 through the real pipeline
- [ ] Scoring emits overall + difficulty-segmented report, judgments cached
- [ ] Baseline report committed and referenced as the acceptance gate for RAG fixes
- [ ] Harness code coverage `>= 95%`; `mix precommit` passes
- [ ] Plan moved to `docs/exec-plans/completed/` when harness is in use
