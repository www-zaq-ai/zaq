# Offline retrieval evaluation fixtures

The regression corpus for `SearchKnowledgeBase` lives in
`test/fixtures/retrieval/`: one JSON file per document in `documents/` and one
JSON file per question in `questions/`. The integration test discovers every
question file automatically. It exercises real `NodeRouter`, SQL vector and
lexical searches, fusion, hydration and public-permission filtering; it uses
stored vectors rather than network calls. Translation generation and embedding
HTTP responses are fixture-backed.

## Add or revise a fixture

1. Add a document JSON with stable `id`, title, full Markdown and ordered
   language-tagged chunks. Every chunk's content must occur verbatim in the
   Markdown. For a mixed document, tag individual chunks as `english`, `french`
   or `arabic` rather than assigning a mixed language to each chunk.
2. Add a question JSON with a stable ID, original question, semantic query and
   lexical groups for **each language present** in the corpus, expected chunk
   references, optional forbidden references and the scenario being judged.
   Lexical groups are alternatives; words in a group form an AND phrase.
3. Set new `embedding` and `embedding_provenance` fields to `null`. Configure a
   multilingual embedding model and its credential/dimension in ZAQ's development
   System Config. Run `mix retrieval.eval.embed` to fill missing vectors via
   `Zaq.Embedding.Client`. The command makes provider calls and rewrites changed
   JSON files; it never changes the indexed database. `--refresh` deliberately
   regenerates **all** vectors after changing a model or source text. `--path DIR`
   selects a different fixture tree. Provider failures leave files unchanged;
   per-file rename errors identify already updated files.
4. Independently judge relevance and compute cosine distances from the stored
   vectors, allowing small halfvec rounding tolerance. Provide tight inclusive
   `vector_distance: [min, max]` intervals on direct vector matches; a lexical-only
   match may use `null`. Mark `ranges_reviewed: true` only after assessing the
   positives, distractors and negatives. The generator never changes expected
   matches, distance ranges or review flags. The model name is recorded, but a
   mutable provider alias alone does not prove immutable weights; review it after
   provider upgrades. Do not store credentials or credential-bearing URLs.

The loader reports the file and JSON field for missing, stale or incompatible
vectors and points to `mix retrieval.eval.embed`. Evaluation fails; it never
silently synthesizes data. Existing vectors must use the same model/dimension
throughout the corpus and questions.

## Run against native or ParadeDB

The vectors were generated with `bge-multilingual-gemma2` at dimension 3584.
The ordinary test database has a different chunk dimension; **do not reset it**.
Use an isolated test partition (and unset local storage-volume imports during
database setup, if set):

```sh
export MIX_ENV=test MIX_TEST_PARTITION=retrieval_eval_native
mix ecto.create && mix db.extensions && mix ecto.migrate
mix test test/zaq/agent/tools/search_knowledge_base_retrieval_evaluation_test.exs --include integration
```

For ParadeDB use `MIX_TEST_PARTITION=retrieval_eval_parade` on a server with a
functional `pg_search` installation. The native partition pins the native
lexical backend even when ParadeDB is installed locally; the ParadeDB partition
requires ParadeDB to be detected. Both run in CI. Fixtures use an **evaluation**
cosine limit of `0.45`, independent of the provisional production default:
the unrelated negative's closest measured distance was `0.589`, while the
lexical-rescue semantic-to-target distance was `0.669`. These tests detect
regressions in this corpus; they do not calibrate production relevance.

CI never calls an embedding provider; only the explicit developer task does.
Follow the [testing handbook](../testing-approach.md) and
[validation lifecycle](../WORKFLOW_AGENT.md#phase-4--validate) for broader checks.
