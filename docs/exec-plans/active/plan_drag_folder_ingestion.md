# Execution Plan: Folder Drag-and-Drop for Ingestion Upload

**Date:** 2026-05-07
**Author:** Jad
**Status:** `active`
**Branch:** `fix/drag-folder`
**PR(s):** TBD

---

## Goal

Allow users to drag a filesystem folder onto the ingestion upload drop zone. A JS hook (`FolderDrop`) walks the directory tree client-side using `DataTransferItem.webkitGetAsEntry()`, filters files by supported extensions, injects accepted files into LiveView's upload queue, and sends skipped-file metadata to the server so the UI can display a clear accepted/skipped summary inline.

Files with unsupported formats (e.g. JSON, XML) are listed with a "unsupported format" label so the user understands why they were not uploaded.

---

## Context

### Docs read
- `docs/services/ingestion.md`
- `docs/phoenix.md`

### Existing code reviewed
- `lib/zaq_web/live/bo/ai/ingestion_live.ex` — upload allow/consume, `@allowed_extensions`, NodeRouter wiring
- `lib/zaq_web/live/bo/ai/ingestion_components.ex` — `upload_section/1`, `phx-drop-target`, entry list, error messages
- `lib/zaq_web/live/bo/ai/ingestion_live.html.heex` — template structure
- `assets/js/app.js` — existing hooks registry; no upload hook present today
- `lib/zaq/ingestion/document_processor.ex` — `@supported_extensions`
- `lib/zaq/ingestion/ingestion.ex` — `upload_file/3`, `ingest_file/3`
- `test/zaq_web/live/bo/ai/ingestion_live_test.exs` — existing test patterns

### Key findings
- `allow_upload(:files, accept: @allowed_extensions, max_entries: 10, max_file_size: 20_000_000)` — existing upload config; no change needed.
- `phx-drop-target` is already on the drop zone `<div>` — hook attaches to that same element.
- No `FolderDrop` hook exists today — new file required.
- `entry.client_relative_path` is available on `UploadEntry` in LiveView 1.1.x — no workaround needed for subfolder paths.
- `ingestion_call/2` → `NodeRouter.call(:ingestion, Ingestion, ...)` is the existing boundary — unchanged.
- **Extension mismatch (pre-existing):** `.txt` is in `@allowed_extensions` but not in `DocumentProcessor.@supported_extensions`. Out of scope here — tracked separately.

---

## Approach

The browser exposes an empty `DataTransfer.files` when a folder is dropped. `DataTransferItem.webkitGetAsEntry()` exposes a `FileSystemDirectoryEntry` that can be walked recursively. The `FolderDrop` hook:

1. Intercepts the `drop` event **before** LiveView's handler.
2. Walks the directory tree using `webkitGetAsEntry()` + `createReader().readEntries()` (paginated — must loop until empty array).
3. Splits files into `supported` (extension in `SUPPORTED_EXTENSIONS`) and `skipped`.
4. Injects accepted `File` objects into the hidden `<input type="file">` via a `DataTransfer` object + synthetic `change` event — the standard LiveView upload injection pattern.
5. Pushes `"folder_drop_skipped"` to the server with `[{name, path, reason}]`.
6. Normal (non-folder) file drops are unaffected — hook detects no directory entries and exits immediately.

---

## Files to Create

| File | Purpose |
|------|---------|
| `assets/js/hooks/folder_drop.js` | `FolderDrop` LiveView hook |

## Files to Modify

| File | Change |
|------|--------|
| `assets/js/app.js` | Import and register `FolderDrop` hook |
| `lib/zaq_web/live/bo/ai/ingestion_components.ex` | Add hook attrs, skipped-list rendering, `skip_reason/1` |
| `lib/zaq_web/live/bo/ai/ingestion_live.ex` | Add `folder_drop_skipped` assign + handler, update `"upload"` to use `client_relative_path` |
| `lib/zaq_web/live/bo/ai/ingestion_live.html.heex` | Pass `folder_drop_skipped` to `<.upload_section />` |

---

## Ordered Steps

### Step 1 — Create `FolderDrop` JS Hook

**File:** `assets/js/hooks/folder_drop.js`

```
SUPPORTED_EXTENSIONS = [".md", ".txt", ".pdf", ".docx", ".pptx", ".xlsx", ".csv", ".png", ".jpg", ".jpeg"]

mounted():
  - addEventListener "dragover" on this.el → preventDefault + dropEffect = "copy"
  - addEventListener "drop" on this.el:
      1. preventDefault + stopPropagation
      2. Check items for directory entries via webkitGetAsEntry()
      3. If no directory entry → return (let LiveView handle normal file drops)
      4. Walk tree recursively (paginated readEntries loop)
      5. Collect File objects via entry.file(cb)
      6. Split: supported (extension check) vs skipped (unsupported_format)
      7. If supported.length > 10: truncate to 10, add remainder as skipped with reason "exceeds_batch_limit"
      8. pushEvent("folder_drop_skipped", {skipped: [{name, path, reason}]})
      9. Inject files into upload input:
           - dt = new DataTransfer()
           - append each supported File
           - input.files = dt.files
           - dispatch new Event("change", {bubbles: true}) on input
```

### Step 2 — Register Hook in `app.js`

```js
import FolderDrop from "./hooks/folder_drop"
// Add FolderDrop to the hooks map
```

### Step 3 — Update `upload_section` Component

**File:** `lib/zaq_web/live/bo/ai/ingestion_components.ex`

- Add `attr :folder_drop_skipped, :list, default: []`
- Add `id="upload-drop-zone"` to the drop zone `<div>` (required for LiveView hooks)
- Add `phx-hook="FolderDrop"` to the drop zone `<div>`
- Render skipped-files section below the entries list:

```heex
<div :if={@folder_drop_skipped != []} class="mt-3 space-y-1">
  <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">Skipped</p>
  <div :for={item <- @folder_drop_skipped} class="flex items-start gap-2">
    <span class="font-mono text-[0.75rem] text-amber-600 truncate max-w-[70%]">{item["name"]}</span>
    <span class="font-mono text-[0.65rem] text-black/30">{skip_reason(item["reason"])}</span>
  </div>
</div>
```

- Add private helper:

```elixir
defp skip_reason("unsupported_format"), do: "unsupported format"
defp skip_reason("exceeds_batch_limit"), do: "batch limit reached (max 10)"
defp skip_reason(_), do: "skipped"
```

### Step 4 — Update `IngestionLive`

**File:** `lib/zaq_web/live/bo/ai/ingestion_live.ex`

**4a.** Add `folder_drop_skipped: []` to `mount/3` assigns.

**4b.** Add event handler:

```elixir
def handle_event("folder_drop_skipped", %{"skipped" => skipped}, socket) do
  {:noreply, assign(socket, folder_drop_skipped: skipped)}
end
```

**4c.** Clear on upload submit — in `handle_event("upload", ...)`:

```elixir
{:noreply,
 socket
 |> assign(folder_drop_skipped: [])
 |> load_entries()
 |> put_flash(:info, "...")}
```

**4d.** Use `client_relative_path` for subfolder placement in `consume_uploaded_entries/3`:

```elixir
relative = entry.client_relative_path || entry.client_name
dest = Path.join(socket.assigns.current_dir, relative)
```

### Step 5 — Update Template

**File:** `lib/zaq_web/live/bo/ai/ingestion_live.html.heex`

Pass the new assign:

```heex
<.upload_section
  uploads={@uploads}
  embedding_ready={@embedding_ready}
  folder_drop_skipped={@folder_drop_skipped}
/>
```

### Step 6 — Verify Parent Directory Creation

**File:** `lib/zaq/ingestion/ingestion.ex` (or `FileExplorer`)

Confirm that writing a file at a nested path (e.g. `"docs/sub/file.pdf"`) auto-creates intermediate directories. If `FileExplorer` does not call `File.mkdir_p!` on the parent, add it in `Ingestion.upload_file/3` before the write. **This is a prerequisite for relative-path support to work for folders with subdirectories.**

### Step 7 — Write Tests

**Files:**
- `test/zaq_web/live/bo/ai/ingestion_live_test.exs` — new tests:
  - `handle_event "folder_drop_skipped"` assigns skipped list
  - `handle_event "folder_drop_skipped"` with empty list — no-op
  - `handle_event "upload"` clears `folder_drop_skipped`
  - `handle_event "upload"` with `client_relative_path` uses relative path for dest
- `test/zaq_web/live/bo/ai/ingestion_components_test.exs` (create if absent) — render tests:
  - `upload_section` with `folder_drop_skipped: [...]` renders skipped list with correct reason text
  - `upload_section` with `folder_drop_skipped: []` renders no skipped section

Coverage target: >= 95% for all modified files.

---

## Architecture Risks

| Risk | Mitigation |
|------|-----------|
| `webkitGetAsEntry()` not W3C spec | Universally shipped (Chrome 21+, FF 50+, Safari 11.1+, Edge 79+). Graceful fallback for non-folder drops required. |
| `max_entries: 10` cap | Hook truncates at 10, reports remainder as `exceeds_batch_limit` |
| Parent directory creation for nested paths | Verify / fix in Step 6 before implementing Step 4d |
| NodeRouter boundary | No new cross-service calls; all existing routing unchanged |
| `.txt` extension mismatch | Pre-existing; out of scope; tracked separately |

---

## Open Questions

1. Does `Ingestion.upload_file/3` → `FileExplorer` call `File.mkdir_p!` on the parent path? (Blocking prerequisite for subfolder support)
2. Should folder drops auto-trigger ingestion, or preserve the current pattern (upload to disk → user clicks ingest)?
3. Batch cap of 10 per drop — acceptable? Or loop in batches?
4. Should the skipped list clear on next folder drop only, or also on page navigation?

---

## Decisions Log

| Decision | Rationale | Date |
|----------|-----------|------|
| JS hook intercepts `drop` before LiveView | Browser `DataTransfer.files` is empty for directories; `webkitGetAsEntry()` is required and must run before LiveView processes the event | 2026-05-07 |
| `webkitGetAsEntry()` not polyfilled | All targeted browsers ship this API | 2026-05-07 |
| Skipped list sent via `pushEvent` | Keeps UX in LiveView; no extra HTTP endpoint needed | 2026-05-07 |
| Subfolder structure preserved via `client_relative_path` | Dropping a folder with subdirs should mirror the structure in the current volume directory | 2026-05-07 |
| `.txt` mismatch not fixed here | Pre-existing issue; out of scope | 2026-05-07 |

---

## Definition of Done

- [ ] `FolderDrop` hook intercepts folder drops, walks tree, splits files by extension, pushes skipped list, injects files into LiveView upload queue
- [ ] Normal (non-folder) file drops continue to work unchanged
- [ ] `handle_event("folder_drop_skipped")` assigns skipped list to socket
- [ ] `handle_event("upload")` uses `client_relative_path` for subfolder placement
- [ ] `handle_event("upload")` clears `folder_drop_skipped` assign on submit
- [ ] `upload_section` renders skipped-files list with human-readable reason text
- [ ] Parent directory creation confirmed safe for nested paths (Step 6)
- [ ] Tests written and passing
- [ ] Coverage >= 95% for all modified files
- [ ] `mix precommit` passes
- [ ] PR opened against `main`
