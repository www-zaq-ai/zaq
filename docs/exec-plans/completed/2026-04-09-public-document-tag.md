# Execution Plan: Public Document Tag

## Plan: Public Access via Document Tag

**Date:** 2026-04-09
**Author:** Jad
**Status:** `completed`
**Related debt:** —
**PR(s):** —

---

## Goal

Add a "Public" access toggle to documents and folders in the ingestion UI. Public access is stored as a `"public"` tag on `documents.tags` — not as a permission row. When a document carries the `"public"` tag, `apply_permission_filter` allows any authenticated user to see its chunks, bypassing the person/team permission check. When a folder is marked public, all existing documents under it receive the tag and a `folder_settings` record persists the flag so future ingests inherit it automatically.

---

## Context

Docs read:
- [ ] `docs/architecture.md`
- [ ] `docs/conventions.md`
- [ ] `docs/services/ingestion.md`

Existing code reviewed:
- `lib/zaq/ingestion/document.ex` — no `tags` field; `metadata` is a plain map
- `lib/zaq/ingestion/permission.ex` — person/team permission rows; `access_rights` array
- `lib/zaq/ingestion/ingestion.ex` — `list_permitted_document_ids/3` used by permission filter; folder helpers exist
- `lib/zaq/ingestion/document_processor.ex:1066` — `apply_permission_filter/4`; delegates to `list_permitted_document_ids`
- `lib/zaq_web/live/bo/ai/ingestion_live.ex` — share modal events wired; `share_modal_permissions` assign
- `lib/zaq_web/live/bo/ai/ingestion_components.ex` — `modal_share` component

---

## Approach

Store public access as a `"public"` string in a new `tags {:array, :string}` column on `documents`. No permission rows are created. `list_permitted_document_ids/3` is extended to union-in any doc that carries `"public"` in its tags, so `apply_permission_filter` requires no change.

Folder-level public state is persisted in a new `folder_settings` table (volume + path + tags). On ingest, if the parent folder has `"public"` in its tags, the document inherits the tag automatically.

The UI adds a "Public access" toggle to the existing share modal (folder and document variants), surfaced via a `toggle_public` LiveView event.

**Why this approach over alternatives:**
- Tag-on-document avoids orphan permission rows and keeps the access model flat and auditable.
- Unioning in `list_permitted_document_ids` keeps `apply_permission_filter` untouched and all permission logic in one place.
- `folder_settings` table is explicit and survives re-ingests; no magic sentinel docs or metadata files.

---

## Steps

### Phase 1 — Red tests (write all failing tests first)

- [ ] **Step 1a:** Write failing tests for `Document` schema — `tags` field, default `[]`, castable, included in upsert conflict replace
- [ ] **Step 1b:** Write failing tests for `FolderSetting` schema — changeset, upsert uniqueness
- [ ] **Step 1c:** Write failing `Ingestion` context tests:
  - `add_document_tag/2`, `remove_document_tag/2`
  - `set_folder_public/2`, `unset_folder_public/2`, `get_folder_tags/2`
  - `list_permitted_document_ids/3` returns public doc ids even when no permission row exists
  - Ingest propagation: document ingested under a public folder inherits the `"public"` tag
- [ ] **Step 1d:** Write failing `DocumentProcessor` integration test — `query_extraction` returns content (not access-denied) for a public-tagged doc when called with a `person_id` that has no permission row
- [ ] **Step 1e:** Write failing LiveView tests (`ingestion_live_test.exs`):
  - Share modal shows "Public access" toggle
  - `toggle_public` event on a document sets/unsets the tag
  - `toggle_public` event on a folder sets/unsets folder setting and propagates to docs

### Phase 2 — Green (implement to make tests pass)

- [ ] **Step 2:** Migration — `add_tags_to_documents_and_create_folder_settings`
  ```
  priv/repo/migrations/<timestamp>_add_public_tag.exs
  ```
  - `alter table(:documents)`: add `tags {:array, :string} default: [] not null`
  - `create index(:documents, [:tags], using: "GIN")`
  - `create table(:folder_settings)`: `volume_name :string`, `folder_path :string`, `tags {:array, :string} default: []`
  - `create unique_index(:folder_settings, [:volume_name, :folder_path])`

- [ ] **Step 3:** `Document` schema — add `tags` field, update `@optional_fields`, update `upsert/1` `:replace` list

- [ ] **Step 4:** New `FolderSetting` schema (`lib/zaq/ingestion/folder_setting.ex`) — `changeset/2`, `upsert/1`

- [ ] **Step 5:** `Ingestion` context — add tag management functions:
  - `add_document_tag(doc_id, tag)` — append if absent via `Repo.update_all`
  - `remove_document_tag(doc_id, tag)` — remove via `array_remove` fragment
  - `set_folder_public(volume, folder_path)` — upsert `FolderSetting` with `"public"`, bulk-add tag to all docs matching `source LIKE "volume/folder_path/%"`
  - `unset_folder_public(volume, folder_path)` — update `FolderSetting`, bulk-remove tag from docs
  - `get_folder_tags(volume, folder_path)` — returns tags list or `[]`

- [ ] **Step 6:** Ingest propagation — after document upsert in `ingest_file/3` (or equivalent), call `get_folder_tags(volume, parent_path)`; if `"public"` present, call `add_document_tag(doc.id, "public")`

- [ ] **Step 7:** `list_permitted_document_ids/3` — union public docs:
  ```elixir
  via_public =
    from(d in Document,
      where: d.id in ^doc_ids and fragment("? @> ARRAY[?]::varchar[]", d.tags, "public"),
      select: d.id
    ) |> Repo.all()

  Enum.uniq(via_permission ++ via_public)
  ```

- [ ] **Step 8:** `ingestion_components.ex` — add "Public access" toggle row to `modal_share`:
  - Globe icon + label ("Anyone can view this content" / "All files in this folder are public")
  - `phx-click="toggle_public"` button
  - Attr `share_modal_is_public` (boolean)

- [ ] **Step 9:** `ingestion_live.ex` — wire UI:
  - Add `share_modal_is_public` assign (default `false`)
  - Populate on modal open: for folder → `"public" in get_folder_tags(...)`, for document → `"public" in doc.tags`
  - Handle `"toggle_public"` event: call `set_folder_public/unset_folder_public` or `add/remove_document_tag`, update assign

- [ ] **Step 10:** (Optional) Public badge on file-explorer rows — small "Public" chip next to file/folder name when tagged

### Phase 3 — Validate

- [ ] **Step 11:** Run `mix test` — all red tests now green, no regressions
- [ ] **Step 12:** Run `mix precommit` — clean
- [ ] **Step 13:** Manual smoke test in dev — toggle public on a document, query the agent, confirm response is not access-denied

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Tag on `documents.tags`, not a permission row | Keeps permission table for person/team grants only; public is a document property, not a grant | 2026-04-09 |
| `folder_settings` table for folder-level state | Explicit, survives re-ingests; queryable without parsing file paths | 2026-04-09 |
| Union in `list_permitted_document_ids` rather than `apply_permission_filter` | All access logic stays in one function; filter itself requires no change | 2026-04-09 |
| GIN index on `documents.tags` | Array containment query (`@>`) requires GIN for performance at scale | 2026-04-09 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| — | — | — |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing (`mix test`)
- [ ] `mix precommit` passes
- [ ] Share modal shows public toggle for both folders and documents
- [ ] `apply_permission_filter` returns content (not access-denied) for public-tagged docs regardless of person/team
- [ ] Folder public flag propagates to newly ingested documents
- [ ] Plan moved to `docs/exec-plans/completed/`
