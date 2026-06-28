# LiveRAG Benchmark (ZAQ harness data)

The [LiveRAG/Benchmark](https://huggingface.co/datasets/LiveRAG/Benchmark) dataset
(arXiv 2511.14531), normalized for ZAQ's RAG benchmark harness. English-only.

## Files

| File | Tracked? | Description |
|---|---|---|
| `liverag.parquet` | ❌ gitignored | Raw upstream download (~4.5 MB). |
| `questions.jsonl` | ❌ gitignored | 895 questions — see schema below. |
| `docs.jsonl` | ❌ gitignored | 970 unique source documents `{doc_id, content}`. |

All data here is **derived, not committed** — regenerate with the Elixir Mix task
(`Mix.Tasks.Zaq.Bench.Liverag.Build`, depends on dev-only `:explorer`):

```sh
mix zaq.bench.liverag.build
```

## `questions.jsonl` schema (one JSON object per line)

| Field | Description |
|---|---|
| `index` | Benchmark index `[0..894]` |
| `question` | The question |
| `answer` | Ground-truth answer |
| `supporting_doc_ids` | 1–2 `doc_id`s into `docs.jsonl` the answer is drawn from |
| `claims` | `{direct, useful, useless}` — used to score answer correctness as claim coverage |
| `session` | `"First"` \| `"Second"` \| `"Both"` |
| `acs` | Average Correctness Score (lower = harder) |
| `irt_diff` | IRT difficulty `[-6..6]` — for segmenting results by hardness |

## Scope

- **Corpus = the 970 attached source docs only** (the closed per-question set), not
  the full 15M-doc FineWeb-10BT corpus. See
  `docs/exec-plans/active/2026-06-27-liverag-benchmark-harness.md`.
- English-only; multilingual eval is a separate, deferred plan (MIRACL + MMTEB).
