# Multilingual text-search support

ZAQ keeps the detected language of every chunk, even when its text-search
index uses a language-neutral fallback. This does not require a custom database
image: stock PostgreSQL configurations are used when available, and an absent
configuration uses `pg_catalog.simple`. On ParadeDB installations the existing
BM25 index remains active; its default analyzer is reported as the equivalent
language-neutral path. Embedding and persistence failures are **not** a fallback:
they remain chunk errors.

The document browser's Ingested badge opens details with the detected-language
chips, segmented progress and the extracted Markdown preview. The segments show
language-specific indexing, language-neutral indexing, and not-yet-indexed/failed
chunks. With ParadeDB's current default analyzer, **all indexed chunks are in the
language-neutral segment**, even if their correctly detected language is French.
This does not mean the detector failed: `chunk.language` and `indexed_languages`
remain French, and searches still translate the query and filter by chunk language.
With native PostgreSQL, the neutral segment represents `simple` fallback.

The counts are stored in `documents.metadata.ingestion`; language-neutral indexed
chunks are included in `total_chunks_indexed` and also counted in the historical
field `total_chunks_simple_indexed`. New summaries store `index_backend` to label
the segment precisely. Older snapshots without a backend use the conservative
“language-neutral indexing” label; no reindex is needed merely to relabel them.

## Add support on an existing PostgreSQL deployment

1. Check which configurations are present in your running server:
   `SELECT n.nspname, c.cfgname FROM pg_ts_config c JOIN pg_namespace n ON n.oid = c.cfgnamespace ORDER BY 1, 2;`
   Availability varies by PostgreSQL version. French, English, Spanish, German,
   Portuguese, Italian, Arabic, Russian and Hindi should be checked explicitly;
   Urdu, Chinese and Japanese normally need separately installed dictionaries
   and/or tokenizing parsers. Merely copying `simple` under a new name does not
   provide language-specific processing.
2. Provision a compatible third-party extension or dictionary **on the database
   host**, following its vendor's version, licensing and backup guidance. ZAQ does
   not install extension binaries or change the shipped database image. Register
   a text-search configuration in `public` whose name matches the detected
   language identifier (for example, `japanese`) and verify stemming/segmentation
   using `to_tsvector` and `websearch_to_tsquery` with that configuration.
3. In a maintenance window, rebuild the generated `content_tsv` column and its
   single GIN index using the approach in
   `priv/repo/migrations/20260923000001_rebuild_multilingual_content_tsv.exs`.
   The generated expression snapshots configurations that exist at column
   creation. **Installing an extension without rebuilding leaves existing and
   future vectors on the former fallback.** The rebuild rewrites and locks the
   `chunks` table; plan for table size, search downtime and a rollback backup.
4. Verify representative indexed chunks and run a language-filtered keyword
   query. If also using ParadeDB, its `chunks_bm25_idx` is separate from the
   native GIN index. Configure and rebuild ParadeDB analyzers separately when
   the installed pg_search version supports the required per-language tokenizer;
   do not disable ParadeDB merely to obtain native FTS.

Changing a configuration's underlying dictionary or tokenizer can change
lexemes without changing its name. Reindex and rebuild affected generated
vectors whenever that happens. Do not manually populate `content_tsv` from
Elixir: PostgreSQL generates it from `content` and `language` on every write.
