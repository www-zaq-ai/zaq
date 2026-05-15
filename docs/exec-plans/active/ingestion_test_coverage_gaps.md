# Execution Plan: Ingestion Test Coverage Gaps

**Branch:** `fix/file-filtering-chat`
**Scope:** Tests only — no new implementation. All production fixes are already merged into this branch; this plan adds the missing regression and integration tests to reach ≥ 95% coverage on every touched file.

---

## Context

The following files were modified in this branch but lack coverage for key branches:

| File | Fix | Untested branch |
|------|-----|----------------|
| `delete_service.ex` | Added `legacy_folder_prefix/3` | Delete folder with legacy absolute-path sources |
| `rename_service.ex` | Added `strip_legacy_prefix/2` | Doubly-corrupted sources via rename |
| `ingestion.ex` | `track_upload` now calls `absolute_to_source` | Upload deduplication through full stack |
| `ingestion.ex` | (indirect) `list_document_sources` | Suggestions after delete |

---

## Step 1 — Delete folder cleans legacy absolute-path sources

### Functional specifications

`DeleteService.delete_documents_by_folder_prefix/3` now includes the legacy prefix
(`volume_name/<abs_base_path>/<folder>/...`) alongside the canonical prefix.
This must be validated end-to-end through `Ingestion.delete_path/4`.

**Files to edit:** `test/zaq/ingestion/ingestion_test.exs`

### Tests to add

```
describe "delete_path/4 and delete_paths/3 recursive cleanup" do

  test "deleting a directory also removes legacy absolute-path document sources"
    # Setup:
    #   1. Create folder on disk via FileExplorer
    #   2. Insert document with canonical source   "default/<folder>/file.md"
    #   3. Insert document with legacy source      "default/Users/.../default/<folder>/file.md"
    # Action: Ingestion.delete_path("default", folder, "directory")
    # Assert: both documents are gone from DB

  test "deleting a directory that exists only in DB (enoent) removes legacy sources"
    # Setup:
    #   1. Do NOT create folder on disk
    #   2. Insert canonical doc + legacy doc for same folder
    # Action: Ingestion.delete_path("default", folder, "directory")
    # Assert: :ok returned, both DB records deleted
end
```

### Branches / paths validated

- `delete_directory_path` → `{:error, :enoent}` path → `delete_documents_by_folder_prefix`
- `delete_documents_by_folder_prefix` with `legacy_folder_prefix` returning a non-empty list
- `source_prefix_conditions` matching both canonical and legacy prefixes

### Mocking plan

None — test through real `FileExplorer` and `Repo`.

### Documentation to update

None. Internal service, no public API change.

---

## Step 2 — Rename fixes doubly-corrupted sources

### Functional specifications

`RenameService.sync_stranded_legacy_docs/4` now calls `strip_legacy_prefix/2` to
recursively unwrap sources whose absolute path has been embedded more than once
(e.g. corrupted twice by the old `track_upload`).

**Files to edit:** `test/zaq/ingestion/rename_service_test.exs`

### Tests to add

```
describe "rename_entry/3 for a directory" do

  test "fixes doubly-corrupted legacy sources (absolute path embedded twice)"
    # Setup:
    #   1. Create folder "zaq" on disk with file "doc.md"
    #   2. Build doubly-corrupted source:
    #      base = FileExplorer.list_volumes()["default"] |> Path.expand()
    #      inner = "default/" <> String.trim_leading(base <> "/zaq/doc.md", "/")
    #      outer = "default/" <> String.trim_leading(base <> "/" <> inner_without_prefix, "/")
    #   3. Insert document with that doubly-corrupted source
    # Action: RenameService.rename_entry("default", "zaq", "product")
    # Assert: document source updated to "default/product/doc.md"
end
```

### Branches / paths validated

- `strip_legacy_prefix/2` recursion depth > 1
- `File.exists?` check resolves file under new folder name
- Canonical doc does not yet exist → update path (not delete)

### Mocking plan

None.

### Documentation to update

None.

---

## Step 3 — `list_document_sources` reflects folder deletes

### Functional specifications

After `Ingestion.delete_path/4` removes a folder, `Ingestion.list_document_sources/1`
must return no suggestions for the deleted folder name. This is the `@mention` regression
from issue #330 applied to the delete side.

**Files to edit:** `test/zaq/ingestion/ingestion_test.exs`

### Tests to add

```
describe "list_document_sources/1 after folder delete" do

  test "suggestions no longer include deleted folder name"
    # Setup:
    #   1. Create folder on disk + document with canonical source
    # Action: Ingestion.delete_path("default", folder, "directory")
    # Assert:
    #   - Ingestion.list_document_sources(folder) returns no entry with label == folder
    #   - Ingestion.list_document_sources(folder) returns no entry whose label contains folder

  test "suggestions no longer include deleted folder when only legacy sources existed"
    # Setup:
    #   1. Create folder on disk + document with LEGACY source only (no canonical)
    # Action: Ingestion.delete_path("default", folder, "directory")
    # Assert: no suggestion for folder in list_document_sources
end
```

### Branches / paths validated

- `list_document_sources` after canonical delete
- `list_document_sources` after legacy-source-only delete
- `derive_folder_prefixes` returns no entry when no documents remain

### Mocking plan

None.

### Documentation to update

None.

---

## Step 4 — Upload deduplication (same folder drag-dropped twice)

### Functional specifications

`Ingestion.track_upload/2` now uses `absolute_to_source` and `Document.upsert`.
Calling it twice for the same absolute path must not create two DB records.
This regression guards against re-ingesting a drag-dropped folder producing duplicates
in `@mention` suggestions.

**Files to edit:** `test/zaq/ingestion/ingestion_test.exs`

### Tests to add

```
describe "track_upload/2" do

  test "upload same file twice produces one document record"
    # Setup: abs_path = Path.join(FileExplorer.list_volumes()["default"], "file.md")
    # Action: track_upload("default", abs_path) called twice
    # Assert: Document.get_by_source(expected_source) != nil
    #         Repo.aggregate(Document, :count, :id) for that source == 1

  test "list_document_sources shows file only once after double upload"
    # Setup + double track_upload
    # Assert: Ingestion.list_document_sources(filename) returns exactly one suggestion
    #         with no duplicate labels
end
```

### Branches / paths validated

- `Document.upsert` on_conflict path
- `absolute_to_source` idempotent for the same absolute path
- `list_document_sources` deduplication

### Mocking plan

None.

### Documentation to update

None.

---

## Step 5 — Rename a folder containing nested subfolders

### Functional specifications

`RenameService.build_directory_multi/4` applies prefix-based bulk updates to all
documents under a folder. When the folder contains subfolders, documents at any depth
must be rewritten.

**Files to edit:** `test/zaq/ingestion/rename_service_test.exs`

### Tests to add

```
describe "rename_entry/3 for a directory" do

  test "updates document sources nested two levels deep"
    # Setup:
    #   1. Create "zaq/sub/deep.md" on disk
    #   2. Document with source "default/zaq/sub/deep.md"
    # Action: rename_entry("default", "zaq", "product")
    # Assert: Document.get_by_source("default/product/sub/deep.md") != nil
    #         Document.get_by_source("default/zaq/sub/deep.md") == nil

  test "list_document_sources after nested rename shows new paths, not old"
    # Setup: two-level nested doc + rename
    # Assert: list_document_sources("product") includes "product/sub" folder
    #         list_document_sources("zaq") returns no match
end
```

### Branches / paths validated

- `rename_source_prefix_query` matching `"old_prefix/%"` for multi-segment paths
- `rename_metadata_key_query` for sidecar pointers inside nested folders
- `list_document_sources` after nested rename

### Mocking plan

None.

### Documentation to update

None.

---

## Coverage Targets

| File | Current estimated coverage gap | Target |
|------|---------------------------------|--------|
| `delete_service.ex` | `legacy_folder_prefix/3` uncalled in tests | ≥ 95% |
| `rename_service.ex` | `strip_legacy_prefix/2` uncalled in tests | ≥ 95% |
| `ingestion.ex` | `list_document_sources` post-delete untested | ≥ 95% |

---

## Definition of Done

- [ ] Step 1 tests written and passing
- [ ] Step 2 tests written and passing
- [ ] Step 3 tests written and passing
- [ ] Step 4 tests written and passing
- [ ] Step 5 tests written and passing
- [ ] `mix test test/zaq/ingestion/` — 0 failures
- [ ] `mix precommit` passes
