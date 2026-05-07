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
// Matches DocumentProcessor.@supported_extensions — intentionally excludes .txt (pre-existing mismatch)
SUPPORTED_EXTENSIONS = [".md", ".pdf", ".docx", ".pptx", ".xlsx", ".csv", ".png", ".jpg", ".jpeg"]
BATCH_SIZE = 10  // matches max_entries; tune both together

Hook state:
  - this._queue = []   // remaining supported File objects

mounted():
  - addEventListener "dragover" on this.el → preventDefault + dropEffect = "copy"
  - addEventListener "drop" on this.el:
      1. Collect items via event.dataTransfer.items
      2. Check for directory entries via webkitGetAsEntry() — scan all items
      3. If no directory entry found:
           - this._queue = []  // reset so folder_batch_done is ignored on next regular upload
           - return            // let LiveView handle normal file drops unchanged
      4. event.preventDefault() + event.stopPropagation()  // only after confirming folder drop
      5. Walk tree recursively (paginated readEntries loop)
      6. Collect File objects via entry.file(cb)
      7. Split: supported (extension check) vs skipped [{name, path, reason: "unsupported_format"}]
      8. this._queue = supported
      9. pushEvent("folder_drop_skipped", {skipped: skipped})
      10. Call this._injectNextBatch()

  // Registered inside mounted() — NOT a top-level lifecycle key:
  this.handleEvent("folder_batch_done", () => {
      if (this._queue.length > 0) this._injectNextBatch()
  })

  _injectNextBatch():
      - input = this.el.closest("form").querySelector("input[type=file]")
      - slice = this._queue.splice(0, BATCH_SIZE)
      - dt = new DataTransfer(); append each File in slice
      - input.files = dt.files
      - dispatch new Event("change", {bubbles: true}) on input
      - this.el.closest("form").requestSubmit()
      // requestSubmit() triggers the LiveView upload submit automatically;
      // after server consumes the batch it pushes "folder_batch_done" → next batch fires
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

**4c.** After upload consume, push batch signal — in `handle_event("upload", ...)`. Do NOT clear `folder_drop_skipped` here; it must persist across batches so the user sees the full skipped list throughout:

```elixir
{:noreply,
 socket
 |> load_entries()
 |> put_flash(:info, "...")
 |> push_event("folder_batch_done", %{})}
```

The hook's `handleEvent("folder_batch_done")` injects the next batch if `this._queue` is non-empty. For regular (non-folder) uploads the hook ignores this event because `this._queue` is reset to `[]` on non-folder drops.

**4e.** Clear `folder_drop_skipped` on the next folder drop — in `handle_event("folder_drop_skipped", ...)`:

```elixir
def handle_event("folder_drop_skipped", %{"skipped" => skipped} = _payload, socket)
    when is_list(skipped) do
  {:noreply, assign(socket, folder_drop_skipped: skipped)}
end

def handle_event("folder_drop_skipped", _bad_payload, socket) do
  {:noreply, socket}
end
```

The guard clause (`when is_list(skipped)`) and the catch-all protect against malformed client payloads.

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

### Step 6 — Verify Parent Directory Creation (confirmed no-op)

`FileExplorer` already calls `File.mkdir_p` on the parent path before every write (verified at `lib/zaq/ingestion/file_explorer.ex` lines 148, 159, 172, 187). No code change required. Nested subfolder paths from `client_relative_path` will work correctly.

### Step 7 — Write Tests

**Write tests first (TDD — red before green).**

**`test/zaq_web/live/bo/ai/ingestion_live_test.exs`** — new tests:
  - `handle_event "folder_drop_skipped"` with valid list assigns skipped list to socket
  - `handle_event "folder_drop_skipped"` with empty list assigns empty list (no-op check)
  - `handle_event "folder_drop_skipped"` with malformed payload (non-list) — socket unchanged, no crash
  - `handle_event "upload"` does NOT clear `folder_drop_skipped` (skipped list persists across batches)
  - `handle_event "upload"` pushes `folder_batch_done` event to client
  - `handle_event "upload"` with `client_relative_path` set uses relative path as dest
  - `handle_event "upload"` with `client_relative_path: nil` falls back to `client_name`

**`test/zaq_web/live/bo/ai/ingestion_components_test.exs`** (create if absent) — render tests:
  - `upload_section` with `folder_drop_skipped: [%{"name" => "x.json", "reason" => "unsupported_format"}]` renders skipped section with "unsupported format" text
  - `upload_section` with `folder_drop_skipped: []` renders no skipped section
  - `upload_section` with `folder_drop_skipped: [%{"name" => "x", "reason" => "unknown_reason"}]` renders catch-all "skipped" text
  - `skip_reason/1` with unknown reason returns "skipped" (tests the catch-all clause explicitly)
  - `upload_section` with `folder_drop_skipped` non-empty — existing upload button still renders correctly (regression guard)

Coverage target: >= 95% for all modified files.

---

## Architecture Risks

| Risk | Mitigation |
|------|-----------|
| `webkitGetAsEntry()` not W3C spec | Universally shipped (Chrome 21+, FF 50+, Safari 11.1+, Edge 79+). Graceful fallback for non-folder drops required. |
| Large folders (hundreds of files) | Hook queues all supported files and feeds them in batches of `BATCH_SIZE` (default 10, matching `max_entries`). Server signals `folder_batch_done` after each upload to trigger the next batch. |
| `folder_batch_done` fired on non-folder uploads | Hook resets `this._queue = []` on non-folder drops; empty queue means `folder_batch_done` is a guaranteed no-op. |
| Parent directory creation for nested paths | Confirmed safe — `FileExplorer` already calls `File.mkdir_p` on parent at every write path. No code change needed. |
| `preventDefault()` order on drop | Must only call after confirming directory entries exist; calling it unconditionally would break normal file drops. See Step 1 pseudocode. |
| `handleEvent` registration | Must be called inside `mounted()`, not as a top-level hook lifecycle key. See Step 1 pseudocode. |
| NodeRouter boundary | No new cross-service calls; all existing routing unchanged |
| `.txt` extension mismatch | Pre-existing; out of scope; tracked separately |

---

## Open Questions

1. Should folder drops auto-trigger ingestion, or preserve the current pattern (upload to disk → user clicks ingest)?
2. Should the skipped list clear on next folder drop only, or also on page navigation?

---

## Decisions Log

| Decision | Rationale | Date |
|----------|-----------|------|
| JS hook intercepts `drop` before LiveView | Browser `DataTransfer.files` is empty for directories; `webkitGetAsEntry()` is required and must run before LiveView processes the event | 2026-05-07 |
| `webkitGetAsEntry()` not polyfilled | All targeted browsers ship this API | 2026-05-07 |
| Skipped list sent via `pushEvent` | Keeps UX in LiveView; no extra HTTP endpoint needed | 2026-05-07 |
| Subfolder structure preserved via `client_relative_path` | Dropping a folder with subdirs should mirror the structure in the current volume directory | 2026-05-07 |
| `.txt` mismatch not fixed here | Pre-existing issue; out of scope | 2026-05-07 |
| No hard cap on folder size — batch instead | No product reason to cap; large folders are processed in sequential batches of `BATCH_SIZE` driven by `folder_batch_done` server event | 2026-05-07 |
| Auto-submit each batch via `requestSubmit()` | Requiring the user to click Upload for each batch of 10 is unacceptable UX for large folders; hook calls `form.requestSubmit()` after injecting each batch | 2026-05-07 |
| `folder_drop_skipped` not cleared between batches | Clearing it after each batch upload would hide the skipped list mid-operation; it persists until the next folder drop replaces it | 2026-05-07 |
| `SUPPORTED_EXTENSIONS` matches `DocumentProcessor`, not `@allowed_extensions` | Avoids silently accepting `.txt` files that pass upload but fail ingestion (pre-existing mismatch; out of scope to fix here) | 2026-05-07 |

---

## Definition of Done

- [ ] `FolderDrop` hook intercepts folder drops, walks tree, splits files by extension, pushes skipped list, injects first batch, auto-submits, and feeds subsequent batches on `folder_batch_done`
- [ ] Normal (non-folder) file drops continue to work unchanged (`preventDefault` only fires after confirming directory entries)
- [ ] `handle_event("folder_drop_skipped")` assigns skipped list; rejects malformed payloads without crashing
- [ ] `handle_event("upload")` uses `client_relative_path` (falls back to `client_name`) for subfolder placement
- [ ] `handle_event("upload")` pushes `folder_batch_done` and does NOT clear `folder_drop_skipped` (persists across batches)
- [ ] `upload_section` renders skipped-files list with human-readable reason text
- [ ] `FileExplorer` parent-directory safety confirmed (no code change needed)
- [ ] Tests written first (TDD), all passing
- [ ] Coverage >= 95% for all modified files
- [ ] `mix precommit` passes
- [ ] PR opened against `main`
