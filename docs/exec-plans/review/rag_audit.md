# RAG Agent Audit Checklist
A step-by-step guide to identify enhancement opportunities in your ingestion pipeline and retrieval system.

---

## 1. Audit Your Ingestion Pipeline

### 1.1 Document Loading
- [ ] What file types are you ingesting? (PDF, HTML, DOCX, plain text?)
- [ ] Are you losing structure during parsing? (tables, headers, lists flattened to plain text?)
- [ ] Are you stripping metadata? (source URL, title, author, date, section name)
- [ ] **Opportunity:** Preserve and store metadata as chunk-level fields for filtering later.

### 1.2 Chunking Strategy
- [ ] What is your chunk size and overlap?
- [ ] Are you chunking by fixed token count, sentence, or paragraph?
- [ ] Are chunks splitting mid-sentence or mid-idea?
- [ ] Is related content ending up in different chunks with no shared context?
- [ ] **Opportunity:** Switch to semantic chunking (split on topic shift) or parent-child chunking (small retrieval chunks that reference a larger parent context window).

### 1.3 Chunk Enrichment
- [ ] Does each chunk carry enough context to be understood standalone?
- [ ] Are you storing the section heading or document title alongside the chunk?
- [ ] **Opportunity:** Prepend each chunk with its document title + section heading before embedding. This dramatically improves vector relevance.

### 1.4 Embedding Quality
- [ ] Which embedding model are you using?
- [ ] Is the model domain-matched to your data? (code, legal, medical, general?)
- [ ] Are you embedding raw chunk text or enriched chunk text?
- [ ] **Opportunity:** Test a stronger or domain-specific embedding model (e.g. `text-embedding-3-large`, `bge-large`, `e5-mistral`).

### 1.5 Index Health
- [ ] Do you have duplicate or near-duplicate chunks in your index?
- [ ] Is stale data being replaced or accumulating?
- [ ] **Opportunity:** Add a deduplication step at ingestion using cosine similarity or hash-based dedup.

---

## 2. Audit Your Retrieval System

### 2.1 BM25 (Keyword Retrieval)
- [ ] Are you preprocessing text consistently? (lowercasing, stopword removal, stemming)
- [ ] Is the BM25 index built on the same text that was embedded?
- [ ] Does BM25 struggle with synonyms or paraphrased queries?
- [ ] **Opportunity:** Add query expansion — use an LLM to generate synonym-enriched variants of the query before BM25 search.

### 2.2 Vector Search
- [ ] Are you using cosine similarity or dot product? (dot product requires normalized vectors)
- [ ] What is your `top_k` value? Is it too low to capture relevant chunks?
- [ ] Are semantically similar but irrelevant chunks ranking high? (precision problem)
- [ ] **Opportunity:** Increase `top_k` then rerank, rather than fetching a small tight set directly.

### 2.3 Hybrid Fusion
- [ ] How are you combining BM25 and vector scores?
- [ ] Are you doing a simple weighted average or Reciprocal Rank Fusion (RRF)?
- [ ] Is the weight between BM25 and vector scores tuned or hardcoded?
- [ ] **Opportunity:** Implement RRF — it is robust, parameter-free, and consistently outperforms weighted averaging.

```
RRF score = Σ 1 / (k + rank_i)   where k = 60 (default)
```

### 2.4 Reranking
- [ ] Do you have a reranker after retrieval?
- [ ] **Opportunity (highest ROI):** Add a cross-encoder reranker (e.g. `cross-encoder/ms-marco-MiniLM-L-6-v2`) on the merged BM25 + vector candidates. This re-scores each chunk against the query with full attention and produces significantly better ranking.

### 2.5 Context Window Passed to LLM
- [ ] How many chunks are you passing to the LLM?
- [ ] Are chunks ordered by relevance or randomly concatenated?
- [ ] Are irrelevant chunks diluting the context?
- [ ] **Opportunity:** Pass only the top 3–5 reranked chunks. More is not always better — noise hurts generation quality.

---

## 3. Audit Your Query Handling

### 3.1 Raw Query Issues
- [ ] Are short or vague queries returning poor results?
- [ ] Does the query language mismatch the document language?
- [ ] **Opportunity:** Add a query rewriting step — prompt the LLM to expand or clarify the user query before retrieval.

### 3.2 Multi-hop Questions
- [ ] Does a single retrieval step fail for questions requiring multiple pieces of information?
- [ ] **Opportunity:** Implement iterative retrieval — after a first pass, let the agent identify what is still missing and trigger a second targeted retrieval.

### 3.3 HyDE (Optional but powerful)
- [ ] **Opportunity:** Before retrieval, prompt the LLM to generate a hypothetical ideal answer, then embed *that* and use it as the vector query. This bridges the vocabulary gap between short queries and long documents.

---

## 4. Audit Your Agent Reasoning

### 4.1 Prompt Design
- [ ] Is the system prompt instructing the agent to use *only* the retrieved context?
- [ ] Is the agent being told to say "I don't know" when context is insufficient?
- [ ] **Opportunity:** Add explicit grounding instructions: "Answer only using the provided context. If the answer is not in the context, say so."

### 4.2 Answer Quality
- [ ] Is the agent hallucinating facts not in the retrieved chunks?
- [ ] Is the agent ignoring retrieved context and relying on parametric memory?
- [ ] **Opportunity:** Add a post-generation grounding check — prompt the LLM to verify each claim in its answer against the retrieved chunks before returning it to the user.

### 4.3 Failure Modes to Check
- [ ] Query returns 0 relevant results — does the agent fail gracefully?
- [ ] Query is ambiguous — does the agent ask for clarification or guess?
- [ ] Retrieved context is contradictory — does the agent notice and surface the conflict?

---

## 5. Priority Order of Enhancements

| Priority | Enhancement | Expected Impact |
|----------|-------------|-----------------|
| 1 | Cross-encoder reranker | High — biggest single quality jump |
| 2 | Parent-child chunking | High — fixes context loss at retrieval |
| 3 | Chunk enrichment (title + heading prepend) | Medium-High — improves embedding relevance |
| 4 | RRF fusion instead of weighted average | Medium — more robust hybrid merging |
| 5 | Query rewriting / expansion | Medium — helps short/vague queries |
| 6 | Post-generation grounding check | Medium — reduces hallucinations |
| 7 | HyDE | Medium — vocabulary gap bridging |
| 8 | Deduplication at ingestion | Low-Medium — index hygiene |

---

## 6. Quick Diagnostic Tests

Run these manually to pinpoint where your pipeline is breaking:

1. **Retrieval precision test** — Take 10 questions you know the answer to. Check if the correct chunk appears in the top 5 retrieved results. If not → retrieval problem.
2. **Generation test** — Hand-feed the correct chunk directly into the LLM prompt. If the answer is still wrong → generation/prompt problem.
3. **Chunking test** — Find an answer that spans two chunks. This exposes chunking boundary issues.
4. **BM25 vs vector test** — Run queries using only BM25 and only vector separately. Compare which misses what. This tells you how to weight your hybrid fusion.
5. **Reranker test** — After reranking, check if the most relevant chunk moved to position 1. If not → reranker model may need a better fit for your domain.
