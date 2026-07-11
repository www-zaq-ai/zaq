# UX Plan — Ingestion Upload Modal

**Source PRD:** User brief (ingestion page upload relocation)  
**Date:** 2026-07-11  
**Status:** Draft — pending review

---

## 1. PRD summary

| Field | Value |
|-------|-------|
| JTBD | Upload files to the local ingestion volume without the upload UI consuming permanent page space |
| Primary users | BO operators managing local ingestion volumes; familiar with file browser + ingest workflow |
| Permissions | Same as today — local provider only (`@provider == "local"`); hidden for external data-source providers |
| In scope | Add **Upload data** toolbar button (before **New Folder**); open modal wrapping existing upload section; remove inline upload from page body; preserve all upload behavior (drop, browse, queue, progress, cancel, submit, skipped-folder list, embedding gate, flash messages); add Storybook story `modal_upload` |
| Out of scope | Upload logic/backend changes; new file types or limits; redesign of dropzone visuals; provider-mode upload |
| Success criteria | Upload works identically to today; page body shows only file browser + jobs panel; button discoverable in toolbar; modal documented in Storybook |

### Key concepts

- **Upload section:** `DesignSystem.Dropzone.upload_section/1` — drop zone, file queue, progress, submit, skipped entries.
- **File browser header:** `DesignSystem.IngestionFileBrowserHeader.file_browser_header/1` — toolbar actions including **New Folder**, **Add Raw MD**, ingest mode, **Ingest Selected**.
- **Modal pattern:** Ingestion modals (`ModalNewFolder`, `ModalAddRaw`, etc.) — `modal: :atom` assign, `show_*_modal` / `close_modal` events.

### Known UX risks

| Risk | Mitigation |
|------|------------|
| Upload hidden behind modal reduces discoverability for first-time users | Prominent secondary button in toolbar; label **Upload data** (action-oriented) |
| Closing modal with queued files | Keep LiveView upload state; reopening modal restores queue (no data loss) |
| Modal too narrow for progress rows | Use wider panel (`max-w-lg` or `max-w-xl`) vs form modals (`max-w-md`) |
| Primary button count | Submit **Upload N file(s)** lives inside modal — does not violate one-primary-per-content-area rule |

### Open questions

- [ ] **Auto-close on success:** Keep modal open after successful upload (matches current inline behavior) — confirm?
- [ ] **Close with in-progress upload:** Allow close while entries are uploading, or block until complete? (Recommend: allow close; uploads continue in LiveView state)

---

## 2. Information architecture

### Navigation

| Item | Location | Route | Notes |
|------|----------|-------|-------|
| Ingestion | Existing sidebar (AI) | `/bo/ai/ingestion` | No new route |

### Page inventory

| # | Screen / view | Change |
|---|---------------|--------|
| 1 | Ingestion — file browser (local provider) | Remove inline upload block; add toolbar trigger |
| 2 | Upload modal | **New** overlay on same route |

### Cross-links

| From | To | Trigger |
|------|-----|---------|
| File browser toolbar | Upload modal | **Upload data** click |
| Upload modal | — (dismiss) | Cancel / backdrop / Escape |

---

## 3. User flows

### Flow A: Upload files via modal (happy path)

**Actor:** BO operator on local volume  
**Trigger:** User has files to add to current directory  
**Goal:** Files uploaded to current folder; jobs panel reflects new ingestion activity

```
1. [Ingestion page] → user clicks **Upload data** → [Upload modal opens]
2. [Upload modal] → user drops files or browses → [Queue entries with progress]
3. [Upload modal] → user clicks **Upload N file(s)** → [Progress completes; flash success]
4. [Upload modal] → user clicks Cancel or Escape → [Modal closes; file list refreshed as today]
```

**Alternates:**
- User opens modal, queues files, closes without submitting → entries remain in LiveView state; reopening shows same queue

**Edge cases:**
- `embedding_ready: false` → submit disabled (unchanged); drop/browse still allowed
- Folder drop with skipped files → **Skipped** list shown inside modal (unchanged)
- Provider / external data source → **Upload data** hidden (same as removed inline section)
- Upload errors → per-entry error messages + flash (unchanged)

### Flow B: Discover upload without modal open

**Actor:** New operator  
**Trigger:** Lands on ingestion page  
**Goal:** Finds upload affordance

```
1. [Ingestion page] → scan toolbar → **Upload data** button visible before **New Folder**
```

---

## 4. Screen specifications

### Screen: Ingestion — File Browser (updated)

**Purpose:** Browse, select, and ingest files; upload moved to modal  
**Route:** `/bo/ai/ingestion`  
**Entry:** Sidebar → Ingestion

#### Layout

```
┌──────────────────────────────────────────────────────────────────┐
│ BOLayout — page_title: Ingestion                                 │
├──────────────────────────────────────────────────────────────────┤
│ [Volume selector — if multiple]                                  │
├──────────────────────────────────────────────────────────────────┤
│ [List/Grid toggle]     [Upload data][New Folder][Add Raw MD]…   │
│ Breadcrumb                                                       │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ File list or grid                                            │ │
│ └──────────────────────────────────────────────────────────────┘ │
│ (upload section REMOVED from body)                               │
├───────────────────────────────┬──────────────────────────────────┤
│                               │ Jobs panel                       │
└───────────────────────────────┴──────────────────────────────────┘
```

#### Content blocks

| Block | Content | Notes |
|-------|---------|-------|
| Chrome row | View toggle + toolbar | **Upload data** is first action (local only) |
| File browser | Breadcrumb + list/grid | Unchanged |
| Jobs panel | Right column | Unchanged |

#### Interactions

| Element | Action | Result |
|---------|--------|--------|
| **Upload data** | click | `show_upload_modal` → `modal: :upload` |
| **New Folder** | click | unchanged |
| Other toolbar | — | unchanged |

#### States

| State | When | What user sees |
|-------|------|----------------|
| Default (local) | `provider == "local"` | Toolbar includes **Upload data**; no inline upload |
| Provider mode | external data source | No **Upload data**; no upload anywhere |
| Modal open | `modal == :upload` | Overlay with upload section |

#### Copy hints

- Button label: **Upload data** (not "Upload" alone — distinguishes from submit inside modal)
- Modal title: **Upload data**
- Modal subtitle: **Add files to the current folder** (or reuse dropzone helper text)

#### Accessibility notes

- **Upload data** button: `id="upload-data-button"`; keyboard activatable
- Modal: focus trap in panel; Escape closes; labelled by modal title

---

### Screen: Upload Modal

**Purpose:** Host full upload workflow previously inline  
**Route:** `/bo/ai/ingestion` (overlay)  
**Entry:** **Upload data** toolbar button

#### Layout

```
┌─────────────────────────────────────────┐
│ ░░░░░░░░░ backdrop ░░░░░░░░░░░░░░░░░░░░ │
│   ┌─────────────────────────────────┐   │
│   │ [icon] Upload data              │   │
│   │        Add files to current dir │   │
│   ├─────────────────────────────────┤   │
│   │  Dropzone.upload_section        │   │
│   │  (drop area, queue, submit,     │   │
│   │   skipped list)                 │   │
│   ├─────────────────────────────────┤   │
│   │              [Cancel]           │   │
│   └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

#### Content blocks

| Block | Content | Notes |
|-------|---------|-------|
| Header | Title + short description | Matches ingestion modal header pattern |
| Body | `Dropzone.upload_section` | **No markup/logic changes** — same attrs: `uploads`, `embedding_ready`, `folder_drop_skipped` |
| Footer | Cancel only | Submit stays inside dropzone form (unchanged) |

#### Interactions

| Element | Action | Result |
|---------|--------|--------|
| Backdrop | click-away | `close_modal` |
| Escape | keydown | `close_modal` |
| Cancel | click | `close_modal` |
| Drop / browse / cancel entry / submit | — | Existing `validate_upload`, `cancel_upload`, `upload` events (unchanged) |

#### States

| State | When | What user sees |
|-------|------|----------------|
| Empty queue | Modal just opened | Drop zone + format hints |
| Queued | Files selected | Progress rows + **Upload N file(s)** |
| Skipped | Folder drop partial | Skipped list (unchanged) |
| Submit disabled | `not embedding_ready` | Primary submit disabled |
| Error | Validation / upload fail | Per-entry errors + flash (unchanged) |

---

## 5. Component mapping

| UX need | Existing component | Gap? |
|---------|-------------------|------|
| Page shell | `BOLayout.bo_layout` | — |
| Toolbar trigger | `DesignSystem.Button` (`:secondary`, icon `hero-arrow-up-tray`) | — |
| Toolbar container | `DesignSystem.IngestionFileBrowserHeader` | **extend** — add Upload data before New Folder |
| Upload body | `DesignSystem.Dropzone.upload_section` | — |
| Modal shell | Ingestion modal pattern (`ModalNewFolder` structure) | **`[NEW COMPONENT]`** `DesignSystem.ModalUpload` — wraps dropzone |
| LiveView wiring | `IngestionLive` + `ingestion_components.ex` delegate | **extend** — `show_upload_modal`, `modal: :upload` |
| File browser chrome story | `storybook/ingestion/ingestion_file_browser_header.story.exs` | **update** — show new button |
| Modal story | — | **`[NEW]`** `storybook/ingestion/modal_upload.story.exs` |

### 5b. Form field mapping

Not applicable — upload uses dropzone + file input, not labeled form fields. Controls:

| Screen | Field / control | Control (module) | Gap? |
|--------|-----------------|------------------|------|
| Upload modal | File picker | `live_file_input` inside `Dropzone` | — |
| Upload modal | Drop target | `Dropzone` + `FolderDrop` hook | — |
| Upload modal | Submit | Primary button inside `Dropzone` form | — |

---

## 6. UX decisions log

| Decision | Rationale |
|----------|-----------|
| **Upload data** before **New Folder** | User-specified order; upload is a common first action when adding content |
| Same `:secondary` button style as **New Folder** | Visual parity in toolbar |
| Reuse `Dropzone.upload_section` verbatim inside modal | Zero functional change; single source of truth |
| New `ModalUpload` module vs inline HEEX | Matches other ingestion modals + enables Storybook story |
| Wider modal than folder/rename modals | Room for progress bars and long filenames |
| Cancel in footer; submit stays in dropzone | Preserves existing form `phx-submit="upload"` wiring |
| Do not auto-close on success | Parity with current inline UX; user may upload multiple batches |
| Hide button when `provider_mode` | Same guard as removed `:if={@provider == "local"}` on upload section |

---

## 7. UI Designer Brief

### Build order (suggested)

1. **`DesignSystem.ModalUpload`** — modal shell + dropzone slot; register in `ingestion_components.ex`
2. **`IngestionFileBrowserHeader`** — add **Upload data** button + `show_upload_modal` event
3. **`IngestionLive`** — `handle_event("show_upload_modal", ...)`, render `modal_upload` when `modal == :upload`
4. **`ingestion_live.html.heex`** — remove inline `<.upload_section>`; add `<.modal_upload>`
5. **Storybook** — `modal_upload.story.exs` + index entry; update `ingestion_file_browser_header` story

### Design system constraints

- Page shell: `BOLayout.bo_layout`
- Tokens: `--zaq-*` only; see `DESIGN.md`
- Reuse: `Dropzone`, `Button`, ingestion modal header/footer pattern
- Icon: `hero-arrow-up-tray` (upload affordance; matches cloud-arrow pattern in dropzone)

### Stories to add/update in Storybook

- [ ] **`modal_upload`** — default (empty queue), with queued entries, with skipped list, embedding not ready
- [ ] **`ingestion_file_browser_header`** — include **Upload data** in toolbar row

### Open for visual design

- [ ] Modal width token (`max-w-lg` vs `max-w-xl`) for progress row comfort
- [ ] Whether modal header icon treatment matches `ModalNewFolder` amber folder icon or uses neutral upload icon

### Out of scope for UI pass

- Upload backend, `allow_upload` config, ingestion job pipeline
- Provider-mode upload
- Migrating legacy ingestion modals to `BOModal` / `modal.css` (separate design-debt effort)

### Prototype handoff

**In-place refactor** on existing `/bo/ai/ingestion` — **not** a new `/bo/{slug}` prototype route.

**`/design` implements §5 verbatim:**

| Row | Action |
|-----|--------|
| `Button` secondary | Wire in header |
| `Dropzone.upload_section` | Render inside `ModalUpload` — no changes to module internals |
| `[NEW] ModalUpload` | Create DSM module + story |
| `IngestionLive` | Modal state + remove body upload |

### Next step

Run **`/design`** on approval (or implement directly on ingestion LiveView). User requested **`modal_upload`** Storybook story as part of this change.
