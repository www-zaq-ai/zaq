# Cosine retrieval rollout

The vector leg uses half-vector cosine distance (`<=>` and
`halfvec_cosine_ops`). Similarity is `1 - distance`; smaller distance is closer.
The inclusive `llm.max_cosine_distance` setting defaults to **0.45** when no
value is persisted (new or upgraded installations). Existing explicitly stored
values are unchanged. This is a provisional starting value, **not**
a mathematical conversion from Euclidean distance or a measured production
optimum. Calibrate it on the issue #793 relevance dataset (identifier,
paraphrase, multilingual and unrelated queries) before considering it final.
The former `llm.distance_threshold` setting is retained unchanged for rollback
and ignored by cosine retrieval. Do not overwrite it with a converted value;
conversion is only justified for normalized embedding vectors.

Migration `20260924000000_use_cosine_chunk_index` changes only the vector index;
it does not write a threshold setting. It drops and recreates
`chunks_embedding_idx` concurrently when the dynamically managed `chunks`
table exists. It skips absent tables; `Chunk.create_table/1` provisions a cosine
index for new tables. Existing nonzero embeddings remain usable without
re-embedding. Index rebuilds consume disk space and temporarily leave vector
search without an ANN index; schedule the migration accordingly and monitor
its duration. PostgreSQL excludes zero vectors from cosine HNSW indexes.
New zero-norm embeddings (including vectors that round to zero at float16
precision) are rejected. Query zero vectors return `:zero_norm_embedding`.

Rollback: pause retrieval traffic, revert the migration to rebuild the L2
index, deploy code using L2, and restore the retained
`llm.distance_threshold` value in the old configuration UI before resuming.
Never serve queries while their operator and index class disagree. Do not regenerate
embeddings solely to switch distance metrics.

Evaluate cosine alone and lexical changes alone against the previous retrieval
baseline, then evaluate their combination. Check recall and false positives at
the default threshold, record the resulting calibrated threshold and update
this document before the final rollout gate.

## Local verification (2026-09-25)

On the branch-specific database `zaq_fix_793_hybrid_retrieval`, cloned from
`zaq_main` with `mix setup.branch zaq_main`, ParadeDB 0.24.0 remained active.
The populated `chunks` table had 43 embedded rows across six documents. The
cosine index was rolled back with `mix ecto.rollback --step 1` and rebuilt with
`mix ecto.migrate`: `pg_get_indexdef` showed L2, then cosine, respectively.
Row count and the aggregate hash of IDs plus serialized embeddings were
identical at each stage. The source `zaq_main` database was not migrated.

An attempt to clone `zaq_dev` first stopped at an **unrelated** credential
preflight migration (`20260918131000`): legacy row 5 lacks an explicit auth
mode. Do not silently classify it as no-auth to get through migration. The
partially migrated branch clone was replaced with the successful `zaq_main`
clone; neither source database was modified.

With six stored embeddings as probes (one per document), both the legacy 1.2
L2 cutoff and provisional 0.75 cosine cutoff admitted all 43 chunks for every
probe. The two metrics agreed on these six top-five sets. This is **not**
evidence that 0.75 is calibrated: stored chunks are not real question
embeddings. A weak same-document proxy over all distinct chunk pairs yielded
precision 0.287 at 0.75 versus 0.479 at 0.40 (recall 1.0 versus 0.819).
Do not adopt 0.40 based on that proxy alone. Representative, judged question
vectors and unrelated negatives are still required before selecting a rollout
default. The real ParadeDB test exercises separate OR clauses, multiword AND,
Boolean-looking literals, language/source filters and the prior whole-query
AND miss without transmitting corpus content to an external provider.
For six additional corpus-derived lexical probes (one indexed term per document
plus a deliberately unrelated term), the old whole-query AND returned zero
matches each time; separate OR clauses returned 1–6 candidates. This checks
the execution path, **not** the quality of generated lexical terms or the
relevance of those candidates.
