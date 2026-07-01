# RAG Audit — ZAQ Findings

Audit of the actual ZAQ ingestion + retrieval pipeline against `rag_audit.md`.
Code refs: `lib/zaq/ingestion/document_processor.ex`, `document_chunker.ex`,
`fts_backend/*`, `lib/zaq/agent/{retrieval,answering}.ex`, `lib/zaq/system.ex`,
seed prompt migration `20260316204749_seed_default_prompt_templates.exs`.

Legend: ✅ done · ⚠️ partial / risk · ❌ missing

---

## 1. Ingestion

| Item | Status | Evidence |
|---|---|---|
| 1.1 File types | ✅ | PDF/DOCX/PPTX/XLSX/CSV/images/MD → Markdown via Python pipeline |
| 1.1 Structure preserved | ✅ | Layout-aware: headings, tables, figures, vision-image blocks detected |
| 1.2 Chunking | ✅ | Hierarchical section detection, 400–900 tok, split by paragraph→sentence; heading stack tracks parent path |
| 1.3 Chunk enrichment | ❌ | **Removed** (commit `ed949b95`). `store_chunk_with_metadata/3` embeds **raw `chunk.content`** — no heading prepend, no LLM `ChunkTitle`. Headings survive only in `section_path` metadata. The `ChunkTitle` module + `chunk_title` template still exist but are no longer wired into ingestion |
| 1.4 Embedding model | ✅ | `bge-multilingual-gemma2`, dim 3584; embeds **raw chunk text** |
| 1.5 Dedup | ❌ | No chunk-level near-duplicate dedup at ingestion (only file-path + image dedup exist) |

**Already strong:** structural chunking (hierarchical section detection, heading stack)
is implemented well. **Note:** chunk enrichment (1.3) is *not* done — it was previously
implemented then removed, so it is now an open opportunity, not a strength.

## 2. Retrieval

| Item | Status | Evidence |
|---|---|---|
| 2.1 BM25 | ⚠️ | Postgres `to_tsvector('english', …)` / ParadeDB `pg_search`. **Hardcoded `'english'`** in FTS backend despite multilingual embeddings + a `LanguageDetector` used at ingestion → non-English content gets wrong stemming/stopwords |
| 2.2 Vector search | ⚠️ | pgvector halfvec, **`<->` (L2 distance), not cosine**, `distance_threshold` default 1.2; per-leg limit `hybrid_search_limit=20`. Verify embeddings are normalized or switch to cosine `<=>` |
| 2.3 Hybrid fusion | ✅ | **RRF, k=60, weighted** (`fusion_bm25_weight`/`fusion_vector_weight`, default 0.5/0.5, configurable). Already the checklist's recommended approach |
| 2.4 Reranking | ❌ | **No cross-encoder reranker.** Biggest gap — checklist's #1 ROI item |
| 2.5 Context to LLM | ⚠️ | Sorted by fused score then doc/section/chunk order, but capped only by **token window fill**, no hard top-3–5 cap → can dilute context with marginal chunks |

## 3. Query handling

| Item | Status | Evidence |
|---|---|---|
| 3.1 Query rewriting | ✅ | `Zaq.Agent.Retrieval.ask/2` rewrites the question into structured JSON queries via LLM (DB `"retrieval"` template) |
| 3.2 Multi-hop / iterative | ❌ | Single retrieval pass; no "what's missing → retrieve again" loop |
| 3.3 HyDE | ❌ | Not implemented |

## 4. Agent reasoning

| Item | Status | Evidence |
|---|---|---|
| 4.1 Grounding prompt | ✅ | "Only use information in retrieved_data"; "Do NOT guess/fabricate/extrapolate"; source citation markers `[[source:…]]` |
| 4.2 No-answer detection | ✅ | `Answering.no_answer?/1` signal phrases + optional logprobs confidence |
| 4.2 Post-gen grounding check | ❌ | No claim-by-claim verification pass against chunks |
| 4.3 Ambiguity / contradiction handling | ❌ | No explicit clarify-or-surface-conflict behavior |

---

## Recalibrated priority order (for ZAQ specifically)

Checklist items 2.3 (RRF), 3.1 (query rewriting), and 4.1 (grounding) are
**already done** — skip them. Note: 1.3 (chunk enrichment) was *previously* done but
**removed** (commit `ed949b95`), so it is back on the table as an opportunity.

| # | Enhancement | Status | Notes |
|---|---|---|---|
| 1 | **Cross-encoder reranker** over merged RRF candidates | ❌ missing | Highest ROI; rerank the ~20/leg before context-window fill |
| 2 | **Fix BM25 language** (use `LanguageDetector` per-doc config, not hardcoded `'english'`) | ⚠️ bug | Real correctness issue for multilingual KB |
| 3 | **Hard top-N (3–5) cap** before LLM, post-rerank | ⚠️ | Reduce context dilution |
| 4 | **Verify vector metric** (`<->` L2 vs normalized/cosine `<=>`) | ⚠️ | Cheap correctness check |
| 5 | Post-generation grounding check | ❌ | Reduce hallucinations |
| 6 | Iterative / multi-hop retrieval | ❌ | For compound questions |
| 7 | HyDE | ❌ | Vocabulary-gap bridging |
| 8 | Chunk-level dedup at ingestion | ❌ | Index hygiene |
| 9 | **Re-introduce chunk enrichment** (heading prepend ± LLM `ChunkTitle`) | ❌ removed | Was implemented then dropped (`ed949b95`); `ChunkTitle` module still present |

**Top 2 to action first:** add a cross-encoder reranker (#1) and fix the
hardcoded-`english` BM25 language mismatch (#2) — the reranker is the largest
quality lever, and the language bug is an outright correctness defect for a
multilingual deployment.
