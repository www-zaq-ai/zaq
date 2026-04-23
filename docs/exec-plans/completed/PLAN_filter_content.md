# Plan: Filter Content — @ Mention Autocomplete for Retrieval Scoping

**Date:** 2026-04-23
**Author:** planning-agent
**Status:** `active`
**Branch:** `feat/filter-content`
**Related debt:** none
**PR(s):** TBD

---

## Goal

Allow BO chat users to type `@` to select ingested content (folders, files, or entire connectors) as filters that scope the retrieval pipeline to only those documents for that message.

The design must be **connector-agnostic**: filesystem volumes, SharePoint, and Google Drive (and any future connector) are all first-class citizens with the same filter contract. No chat or retrieval code should know about specific connector types.

---

## Context

### Roles affected
- `:bo` — ChatLive, JS hook, template
- `:ingestion` — DocumentProcessor search, new `list_document_sources` query
- `:agent` — Pipeline threads the filter through to `query_extraction`

### Key existing code
- `lib/zaq_web/live/bo/communication/chat_live.ex` — BO chat LiveView, `run_pipeline_async/6`, `Event.new/3` construction
- `lib/zaq_web/live/bo/communication/chat_live.html.heex` — textarea input bar
- `lib/zaq/agent/pipeline.ex` — `do_query_extraction/2` calls `NodeRouter.call(:ingestion, DocumentProcessor, :query_extraction, ...)`
- `lib/zaq/ingestion/document_processor.ex` — `query_extraction/2`; `retrieve/1` calls `bm25_search_group_by` and `similarity_search_group_by`; no current source filter
- `lib/zaq/ingestion/document.ex` — `Document.source_prefix_conditions/1` already exists; `source` is the canonical path key
- `lib/zaq/ingestion/ingestion.ex` — public ingestion API; `Document.list/0` accessible

---

## Approach

### Connector prefix convention
`Document.source` already encodes a connector via its first path segment:

| Connector | source prefix example |
|---|---|
| Filesystem volume `"documents"` | `"documents/hr/policy.md"` |
| SharePoint (future) | `"sharepoint/sites/hr/policy.docx"` |
| Google Drive (future) | `"gdrive/shared/reports/q4.pdf"` |

The first segment is the **connector identifier**. All filtering, grouping, and display is derived from this prefix — no connector-specific code is needed anywhere else.

### `ContentSource` struct (new)
A single canonical struct used by the filter system end-to-end:

```elixir
%Zaq.Ingestion.ContentSource{
  connector: :filesystem | :sharepoint | :gdrive | atom(),  # first source segment
  source_prefix: String.t(),   # e.g. "documents/hr/" or "sharepoint/"
  label: String.t(),           # human-readable display name
  type: :connector | :folder | :file  # :connector = top-level entry for entire connector
}
```

The `:connector` type entry covers the case where a user wants to scope to all SharePoint documents without picking a specific folder. Retrieval filters on `"sharepoint/"` prefix.

### Connector registry (new, simple)
`Zaq.Ingestion.ConnectorRegistry` — a lightweight behaviour + config-driven registry that maps a source prefix segment to connector metadata (display name, icon key). For now it has one implementation: filesystem volumes (read from `list_volumes/0`). Future connectors register themselves by adding an entry. The registry has no knowledge of the retrieval or chat layers.

```elixir
# today
ConnectorRegistry.list_connectors() #=> [%{id: "documents", label: "Documents", icon: :folder}]

# after SharePoint connector ships
ConnectorRegistry.list_connectors() #=> [
#   %{id: "documents", label: "Documents", icon: :folder},
#   %{id: "sharepoint", label: "SharePoint", icon: :sharepoint},
#   %{id: "gdrive",     label: "Google Drive", icon: :gdrive}
# ]
```

### Data model
Filters are **per-message, ephemeral socket state** — a list of `%ContentSource{}` structs. They are not persisted. Per-message ephemerality is the right scope because a follow-up may want different scope; no migration to `messages` or `conversations` is needed.

### Retrieval layer
`DocumentProcessor.query_extraction/2` accepts an `access_opts` keyword list. A new `:source_filter` key (list of `source_prefix` strings, extracted from `ContentSource` structs before crossing the NodeRouter boundary) will be added. When non-empty it adds a `WHERE document.source LIKE "prefix/%" OR ...` clause to both BM25 and vector search legs using the already-existing `Document.source_prefix_conditions/1` helper.

The retrieval layer only ever sees plain prefix strings — it has no awareness of connectors.

### @ autocomplete UX
A JS hook `ContentFilter` on `#chat-input` detects `@<query>`, pushes `"filter_autocomplete"` to LiveView. The LiveView queries via `NodeRouter` to `:ingestion`, which calls `ConnectorRegistry` + `list_document_sources/1` and returns `%ContentSource{}` structs. The dropdown groups suggestions by connector. Selecting fires `"add_content_filter"`; filters display as chips with a connector-appropriate icon.

**Same filename, two connectors — how the dropdown looks:**

```
┌─────────────────────────────────────┐
│  📁 Documents                       │  ← connector section header
│    📄 report.md                     │  ← source: "documents/hr/report.md"
│                                     │
│  ☁️ Google Drive                    │  ← connector section header
│    📄 report.md                     │  ← source: "gdrive/shared/hr/report.md"
└─────────────────────────────────────┘
```

The connector section header is the disambiguation. Labels are not made unique artificially. A chip added from each row carries its own `source_prefix`, so both can be active simultaneously:

```
[📁 report.md ×]  [☁️ report.md ×]   Ask a question…
```

### `Zaq.Event` and `%Incoming{}` — the right carrier

`%Incoming{}` is the **canonical inbound message struct** that every channel adapter (BO chat, Mattermost, and future Slack/Teams) must construct before dispatching. It is the universal contract between channels and the pipeline.

A new `content_filter: []` field is added to `%Incoming{}`. This is the right place because:
- The pipeline receives `%Incoming{}` directly — `Pipeline.run(incoming, opts)` — so it can read `incoming.content_filter` without any threading through event assigns or pipeline opts
- `Zaq.Agent.Api` already calls `pipeline_module.run(incoming, pipeline_opts)` — no change needed there
- Every channel adapter is independently responsible for populating the field when the user expresses a filter (see Channel Adapter Contract below)

`%Zaq.Event{}` does **not** change. The filter travels inside `incoming.content_filter`, not in `event.assigns`.

### Channel adapter contract
Any channel that supports content filtering must:
1. Parse `@<mention>` tokens from the raw message text before constructing `%Incoming{}`
2. Resolve the mentions to source prefixes via `NodeRouter.dispatch/1` to `:ingestion` (calls `list_document_sources/1`)
3. Strip the `@<mention>` tokens from `incoming.content` (so they don't confuse the LLM)
4. Set `incoming.content_filter` to the resolved prefix list

**BO chat**: filters are resolved in the UI (chips). Before constructing `%Incoming{}`, the socket serializes `active_filters` to `Enum.map(filters, & &1.source_prefix)` and sets `content_filter`.

**Mattermost** (future): the channel adapter receives raw message text containing `@documents/hr`. It calls `NodeRouter` to resolve → gets back `["documents/hr/"]` → sets on `%Incoming{}` → strips the token from `content`.

**Any future channel**: same contract — parse, resolve, strip, set. Zero changes to the pipeline or retrieval layer.

### Retrieval filtering — exactly what `query_extraction` does
`do_query_extraction/2` in `pipeline.ex` reads `incoming.content_filter` from the `%Incoming{}` struct (passed as a pipeline opt after extraction) and adds it to the `access_opts` list as `:source_filter`.

Inside `DocumentProcessor.query_extraction/2`, the `:source_filter` list drives a `WHERE` clause that ANDs against the existing permission checks:

```sql
-- simplified; both search legs get this filter
WHERE (
  d.source LIKE 'documents/hr/%'
  OR d.source LIKE 'documents/reports/annual-report.md'
)
AND (
  -- existing permission check: person_id / team_ids / public
)
```

`Document.source_prefix_conditions/1` already generates this fragment. The result: only chunks whose parent document `source` matches one of the selected prefixes are returned. The permission check still applies on top — a filter doesn't grant access to documents the user couldn't see otherwise.

---

## Steps

### Step 1 — `Zaq.Ingestion.ContentSource` struct
- [ ] Create `lib/zaq/ingestion/content_source.ex`
- Defines `%Zaq.Ingestion.ContentSource{connector, source_prefix, label, type}`
- `type` is `:connector | :folder | :file`
- No Ecto schema — this is a plain struct, not persisted
- Add `from_source/1` helper: parses a raw `Document.source` string into the struct by splitting on `/`

### Step 2 — `Zaq.Ingestion.ConnectorRegistry`
- [ ] Create `lib/zaq/ingestion/connector_registry.ex`
- `list_connectors/0` — returns `[%{id: String.t(), label: String.t(), icon: atom()}]`
- Reads from channel config to determine which ingestion channels are active:
  - Filesystem: reads `FileExplorer.list_volumes/0`, maps each volume to `%{id: volume_name, label: volume_name, icon: :folder}`
  - Future connectors (SharePoint, GDrive): check if their channel is configured and enabled in application config
- No ETS table, no runtime `register_connector/3` API — config-driven only; active connectors are known at startup

### Step 3 — `Zaq.Ingestion.list_document_sources/1`
- [ ] Add to `lib/zaq/ingestion/ingestion.ex`
- Signature: `list_document_sources(query \\ nil) :: [%ContentSource{}]`
- Queries `Document.source`; when `query` given, applies a `LIKE` filter
- Groups into `:file` (leaf sources), `:folder` (non-leaf path segments), and `:connector` (top-level connector entries from `ConnectorRegistry`)
- Returns max 50 results total, ordered by `source`, with `:connector` entries always at the top
- `:ingestion`-role function; BO must call via `NodeRouter.dispatch/1`

### Step 4 — Add `content_filter` to `%Incoming{}`
- [ ] Modify `lib/zaq/engine/messages/incoming.ex`
- Add `content_filter: []` field (list of source-prefix strings)
- Type: `[String.t()]`
- Default `[]` — no filter applied when absent, existing behaviour preserved
- No `@enforce_keys` change needed

### Step 5 — `Pipeline`: read `incoming.content_filter` in `do_query_extraction/2`
- [ ] Modify `lib/zaq/agent/pipeline.ex`
- `Pipeline.do_query_extraction/2` receives `%Incoming{}` — read `incoming.content_filter` directly and add as `source_filter:` to the `access_opts` list in the `NodeRouter.call` to `DocumentProcessor.query_extraction`
- No opts threading through `run/2` or `do_run/2` — read from the struct at the point of use
- `Zaq.Agent.Api` — **no change needed**; the filter is already in `incoming.content_filter`

### Step 6 — `DocumentProcessor.query_extraction/2` with `:source_filter` opt
- [ ] Modify `lib/zaq/ingestion/document_processor.ex`
- Extract `source_filter = Keyword.get(access_opts, :source_filter, [])` alongside existing permission opts
- Pass into `retrieve/2` (rename private `retrieve/1` → `retrieve/2`)
- In `retrieve/2`, pass `source_filter` to both `bm25_search_group_by/3` and `similarity_search_group_by/2`
- When `source_filter` is empty, behaviour is identical to current (no regression)
- Keep 2-arity default on `bm25_search_group_by` for backward compat (it is public and tested)

Notes:
- `bm25_search_group_by` does NOT currently join `Document` — add an explicit INNER JOIN on `document_id`; verify `paradedb.score(c.id)` still works with the ParadeDB extension
- `similarity_search_group_by` already joins `Document` via alias `d` — add `where(^source_prefix_condition)` using the existing `d` binding
- Source filter ANDs with existing permission check — it narrows, never widens

### Step 7 — NodeRouter-dispatchable Ingestion entrypoint
- [ ] Check whether `lib/zaq/ingestion/api.ex` or equivalent already exists
- If not: create `Zaq.Ingestion.Api` handling `:list_document_sources` action, modelled after `lib/zaq/agent/api.ex`
- Register in the NodeRouter dispatch table for `:ingestion` destination

### Step 8 — `ChatLive`: socket state and event handlers
- [ ] Add to `mount/3` assigns:
  - `:active_filters` — `[]` — list of `%ContentSource{}` structs
  - `:filter_suggestions` — `[]` — list of `%ContentSource{}` structs, grouped by connector
  - `:filter_query` — `""`
- [ ] `"filter_autocomplete"` — dispatches via `NodeRouter.dispatch/1` to `:ingestion`; assigns `[%ContentSource{}]` to `:filter_suggestions`
- [ ] `"add_content_filter"` — appends to `:active_filters` (deduplicated by `source_prefix`); clears suggestions
- [ ] `"remove_content_filter"` — removes matching entry from `:active_filters`
- [ ] `"clear_content_filters"` — resets to `[]`
- [ ] Modify `handle_event("send_message", ...)` — pass `active_filters` into `run_pipeline_async/7`; reset `:active_filters` to `[]` after send
- [ ] `run_pipeline_async/7` — serialize to plain strings (`Enum.map(filters, & &1.source_prefix)`); set as `content_filter:` on the `%Incoming{}` struct constructed inside the function — **not** in `event.assigns`

### Step 9 — JS hook: `ContentFilter`
- [ ] Create `assets/js/hooks/content_filter.js`
  - On `keyup`/`input`: detect `@<query>` token; push `"filter_autocomplete"` with `{query: afterAt}`
  - On space/enter after selection, or Escape: clear suggestions via `"filter_autocomplete"` with `{query: null}`
  - On suggestion click: push `"add_content_filter"`; remove `@query` token from textarea value
- [ ] Register in `assets/js/app.js` as `ContentFilter`

### Step 10 — Template
- [ ] Modify `lib/zaq_web/live/bo/communication/chat_live.html.heex`

**Chip strip** (above textarea, renders when `@active_filters != []`):
- Each chip shows: `[connector-icon] label ×`
- `connector-icon` is resolved from `ConnectorRegistry` by `filter.connector` — e.g. `:folder` SVG for filesystem, `:sharepoint` SVG for SharePoint
- `×` fires `"remove_content_filter"` with `phx-value-source_prefix={filter.source_prefix}`
- Two chips with the same `label` but different `connector` are both valid — the icon is the disambiguation, not the label

**Autocomplete dropdown** (renders when `@filter_suggestions != []`):
- Suggestions are **grouped by connector** using `Enum.group_by(suggestions, & &1.connector)`, ordered by `ConnectorRegistry` order
- Each connector group has a sticky section header: `[connector-icon] connector-label` (e.g. "Google Drive")
- Within a group, entries show: `[type-icon] label` where type-icon is a folder or file glyph (from `suggestion.type`)
- When two entries have the same `label` in different connector groups, the section header provides the visual disambiguation — no need to show the full source path in the label
- Each suggestion button: `phx-click="add_content_filter"` with `phx-value-source_prefix`, `phx-value-connector`, `phx-value-label`, `phx-value-type`

**`"add_content_filter"` handler** (in ChatLive):
- Builds a `%ContentSource{}` from the four phx-values
- Deduplication key is `source_prefix` — same file from two different connectors would have different `source_prefix` values, so both can be added independently

**Textarea**: add `phx-hook="ContentFilter"`, update placeholder to `"Ask a question… Type @ to filter by source"`

### Step 11 — Tests
- [ ] `test/zaq/ingestion/content_source_test.exs` — `from_source/1` parses all connector prefix patterns correctly
- [ ] `test/zaq/ingestion/connector_registry_test.exs` — `list_connectors/0` returns filesystem volumes; `register_connector/3` adds new entries
- [ ] `test/zaq/ingestion/document_processor_test.exs` — `:source_filter` filters out non-matching documents
- [ ] `test/zaq/ingestion/ingestion_test.exs` — `list_document_sources/1` with/without query; returns `:connector` entries from registry
- [ ] `test/zaq/agent/pipeline_test.exs` — `:content_filter` flows through to `DocumentProcessor` NodeRouter call
- [ ] `test/zaq_web/live/bo/communication/chat_live_test.exs` — filter event handlers; reset on send; chip icon reflects connector type

### Step 12 — Docs + precommit
- [ ] Run `mix precommit` and `mix test`
- [ ] Update `docs/services/agent.md` (`:content_filter` pipeline opt)
- [ ] Update `docs/services/ingestion.md` (`ContentSource`, `ConnectorRegistry`, `list_document_sources`, `:source_filter`)

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Filters are per-message, not per-conversation | Avoids migration on `conversations`; user intent is ephemeral; simpler to reason about | 2026-04-23 |
| `active_filters` reset after send | Prevents stale scope on follow-up questions | 2026-04-23 |
| Source filter uses `LIKE` prefix match on `Document.source` | `Document.source_prefix_conditions/1` already implements this; consistent with volume-prefixed source naming | 2026-04-23 |
| `content_filter` lives on `%Incoming{}`, not `event.assigns` | `%Incoming{}` is the universal channel contract — every channel adapter constructs it, and `Pipeline.run/2` receives it directly. Using `event.assigns` would require `Agent.Api` to thread it into pipeline opts manually and hides the contract from channel adapters | 2026-04-23 |
| Autocomplete uses NodeRouter to `:ingestion` | BO must never call `Zaq.Ingestion` directly — multi-node safety | 2026-04-23 |
| `@` autocomplete is a JS hook pushing LiveView events | Avoids full-page re-render on each keystroke | 2026-04-23 |
| No changes to `Conversation` or `Message` schemas | Per-message ephemeral design eliminates the need for a migration | 2026-04-23 |
| `Document.source` first segment is the connector identifier | Already true for filesystem volumes; SharePoint/GDrive connectors will register their own prefix (`"sharepoint"`, `"gdrive"`); no schema change needed | 2026-04-23 |
| `ContentSource` struct is a plain struct, not Ecto | Filters are ephemeral and cross NodeRouter as serialized prefix strings; a plain struct avoids accidental Ecto coupling and is safe for Erlang distribution | 2026-04-23 |
| `ConnectorRegistry` is config-driven, not DB or ETS | Active connectors are known from channel config at startup; no runtime registration API needed; keeps the registry simple and stateless | 2026-04-23 |
| Retrieval layer sees only plain prefix strings, never `ContentSource` | Keeps the retrieval pipeline connector-agnostic; `ContentSource` is purely a UI/presentation concern | 2026-04-23 |

---

## Architecture Risks

- **`content_filter` on `%Incoming{}` is a channel responsibility** — the pipeline trusts whatever prefix strings arrive in `incoming.content_filter`. Validation (do these prefixes actually exist? does the user have access?) is enforced by the permission check inside `query_extraction`, not by the pipeline itself. A channel that sets a bogus prefix gets back empty results, not an error.
- **Strip `@mention` tokens from `incoming.content`** — each channel adapter MUST remove `@<mention>` tokens from the message content before setting `incoming.content`. If not stripped, the LLM will see them and may interpret them as part of the question.
- **NodeRouter boundary** — `"filter_autocomplete"` in ChatLive MUST use `NodeRouter.dispatch/1` to `:ingestion`, never a direct call to `Zaq.Ingestion.list_document_sources/1`. Direct call breaks multi-node deployments.
- **BM25 JOIN** — `bm25_search_group_by` currently does NOT join `Document`. Adding an INNER JOIN for the source filter must not break `paradedb.score(c.id)`. Verify with the ParadeDB extension present.
- **`bm25_search_group_by/2` is public and tested** — the new 3-arity variant must default `source_filter \\ []`; do not change existing call sites.
- **`similarity_search_group_by` already joins `Document`** — add the WHERE clause using the existing `d` alias binding.
- **Task.async closures** — `source_filter` is captured in async task closures; it must be a plain list of strings (safe for Erlang distribution), not a `%ContentSource{}` struct.
- **ConnectorRegistry is config-driven, not runtime-registered** — `list_connectors/0` reads channel config at call time; no supervisor initialization required. Future connectors appear in the list only when their channel is configured and enabled in application config.

---

## Open Questions

1. Does `Zaq.Ingestion.Api` (NodeRouter entrypoint for `:ingestion`) already exist? Read `lib/zaq/ingestion/` before Step 7.
2. Should `@` autocomplete search `Document.title` in addition to `source` paths? Currently `source`-only; title matching may improve UX but adds complexity.
3. Should the `:connector` type `ContentSource` (scope entire connector) be supported at launch, or only `:folder` and `:file`? Including it is low-cost since the prefix is just `"sharepoint/"`, but it changes the UX hierarchy.
4. What is the icon/display strategy for filesystem volumes when there are multiple volumes with custom names? `ConnectorRegistry` currently uses volume name as label — should it be configurable?

---

## Definition of Done

- [ ] All steps above completed
- [ ] `mix test` passes with no failures
- [ ] `mix precommit` passes
- [ ] `query_extraction` with non-empty `:source_filter` only returns chunks from matching documents (unit test)
- [ ] `ConnectorRegistry.list_connectors/0` returns filesystem volumes; `register_connector/3` adds entries visible immediately
- [ ] `list_document_sources/1` returns `:connector` entries from the registry plus `:folder`/`:file` entries from DB
- [ ] `ContentSource.from_source/1` correctly parses `"sharepoint/sites/hr/doc.pdf"` as `%{connector: "sharepoint", type: :file, ...}`
- [ ] BO chat: typing `@` shows connector-grouped suggestions
- [ ] BO chat: selecting a suggestion adds a chip with the correct connector icon
- [ ] BO chat: chips are cleared after message send
- [ ] Multi-node: `"filter_autocomplete"` routes through NodeRouter (not a direct call)
- [ ] Adding a future connector only requires: (1) calling `ConnectorRegistry.register_connector/3` at supervisor start, (2) ingesting documents with the new prefix — zero changes to chat, pipeline, or retrieval code
- [ ] `docs/services/agent.md` and `docs/services/ingestion.md` updated
- [ ] Plan moved to `docs/exec-plans/completed/`
