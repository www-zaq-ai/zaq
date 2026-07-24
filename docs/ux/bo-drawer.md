# UX Plan — BO Drawer Component

**Source:** User requirements (component spec + Agents reference)  
**Date:** 2026-07-24  
**Status:** Draft — open questions resolved

---

## 1. PRD summary

| Field | Value |
|-------|-------|
| **JTBD** | Give BO users a consistent slide-over panel for create/edit flows without leaving list context. |
| **Primary users** | BO admins (Agents, Skills, People-style pages). |
| **Permissions** | Same as host page; drawer does not change auth. |
| **In scope** | Reusable drawer shell: parent-controlled open state, **all four placements**, two width/height sizes, padding modes, header/body/footer slots, modal-equivalent backdrop, close via X / backdrop / Escape. |
| **Out of scope** | Replacing all `MasterDetailLayout` pages in one pass; nested drawer stacking; production Agents wiring (prototype uses fixtures demo page). |
| **Success criteria** | One primitive used across BO; demo page exercises all placements/sizes; Agents reference spec uses **2/3** drawer; behavior aligns with `BOModal` parent-state patterns. |

### Key concepts

- **Drawer shell:** Overlay + sliding panel (not inline split pane).
- **Host page:** List/table stays visible (dimmed); drawer holds form or detail.
- **Separate overlay context:** Primary actions inside drawer don't count toward the "one `.zaq-btn-primary` per page" rule (`DESIGN.md`).

### Resolved decisions

| Question | Decision |
|----------|----------|
| MVP placements | **All four:** `left`, `right`, `top`, `bottom` |
| Top/bottom sizing | **1/3 and 2/3 viewport height** (analog to left/right width) |
| Agents create/edit default size | **`:two_thirds`** (2/3) |
| Focus trap + scroll lock | **Required for drawer MVP** — see §6 and §6b |

### Known UX risks

| Risk | Mitigation |
|------|------------|
| Agents today uses inline `MasterDetailLayout` | Drawer is overlay model; migration is intentional UX shift |
| Nested overlays (Agents MCP/tools/skills modals) | Modals stay above drawer; z-index documented in CSS |
| Top/bottom on small viewports | 2/3 height may feel tall — acceptable for MVP; responsive pass deferred |

---

## 2. Information architecture

Design-system primitive — no new sidebar item for the component itself.

| Host / demo | Entry | Drawer use | Route |
|-------------|-------|--------------|-------|
| **Drawer demo (prototype)** | Sidebar or dev link | All placement/size/padding variants | `/bo/drawer` |
| Agents (reference, post-prototype) | "New Agent" / row select | Create / edit form | `/bo/agents` |
| Skills (future) | Create / edit | Same pattern | `/bo/skills` |
| People (future) | Detail | Person/team detail | `/bo/people` |

Every host screen sits inside `BOLayout.bo_layout`.

---

## 3. User flows

### Flow A: Open drawer (happy path)

**Actor:** BO admin  
**Trigger:** Primary action (e.g. "New Agent")  
**Goal:** Complete create/edit without route change

```
1. [List page] → click New Agent → parent sets is_open: true
2. [Drawer opens] → backdrop dims list; panel slides in (default: from right, 2/3 width)
3. Focus moves into drawer (first focusable or title)
4. [Header] title + close; [Body] form; [Footer] Cancel + Save
5. Save success → parent closes drawer or keeps open in edit mode
```

### Flow B: Close drawer

**Trigger:** Close button, backdrop click, Escape, Cancel

```
1. User closes → on_close fires → parent sets is_open: false
2. Focus returns to element that opened drawer
3. Body scroll restored; drawer unmounts/hides
```

### Flow C: Nested modal (Agents reference)

```
1. Drawer open with agent form
2. User clicks "Add MCP" → BOModal.form_dialog above drawer
3. Modal dismiss → focus returns to drawer
```

**Edge cases**

| Case | Behavior |
|------|----------|
| `is_open: false` | Not rendered |
| Long form | Body scrolls; header/footer pinned |
| Loading save | Footer primary loading state |
| Error | Inline in body; drawer stays open |

---

## 4. Component specification

### Component: BO Drawer Shell

**Purpose:** Uniform overlay panel for BO create/edit flows  
**Module:** `ZaqWeb.Components.Drawer`

#### Size mapping

| `size` attr | Left / Right | Top / Bottom |
|-------------|--------------|--------------|
| `:one_third` | 33.333vw width | 33.333vh height |
| `:two_thirds` | 66.666vw width | 66.666vh height |

Default: `:two_thirds` for form drawers (Agents reference).

#### Layout zones (placement: right, size: two_thirds)

```
┌─────────────────────────────── viewport ───────────────────────────────┐
│ [Dimmed page content — list still visible under backdrop]            │
│                                    ┌──────── drawer panel (2/3 w) ────┐
│                                    │ HEADER: title    [optional] [X]  │
│                                    ├──────────────────────────────────┤
│                                    │ BODY (scroll)                    │
│                                    │   form fields…                   │
│                                    │                                  │
│                                    ├──────────────────────────────────┤
│                                    │ FOOTER: Cancel    [Primary Save] │
│                                    └──────────────────────────────────┘
└──────────────────────────────────────────────────────────────────────┘
```

#### Layout zones (placement: top, size: one_third)

```
┌──────────────── drawer (1/3 h) ──────────────────────────────────────┐
│ HEADER │ BODY (scroll) │ FOOTER                                        │
├──────────────────────────────────────────────────────────────────────┤
│ [Dimmed page content below]                                          │
└──────────────────────────────────────────────────────────────────────┘
```

#### API contract

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | string | Required; drives `aria-labelledby` |
| `is_open` | boolean | Parent-owned; **no internal open state** |
| `on_close` | string or `%Phoenix.LiveView.JS{}` | Backdrop, Escape, header close |
| `placement` | `:left` \| `:right` \| `:top` \| `:bottom` | Default `:right` |
| `size` | `:one_third` \| `:two_thirds` | Width (L/R) or height (T/B) per table above |
| `padding` | `:default` \| `:flush` | Default = modal body rhythm; flush = edge-to-edge |
| `return_focus_id` | string, optional | Element id to restore focus on close |
| `rest` | global, `include: [:js]` | test ids, aria-*, extra classes |

#### Slots

| Slot | Required | Content |
|------|----------|---------|
| `:header` | Optional | Title row; shell **always** renders close wired to `on_close` |
| default | Required | Scrollable body |
| `:footer` | Optional | Action row |

#### States

| State | When | User sees |
|-------|------|-----------|
| Closed | `is_open: false` | Host page only |
| Open | `is_open: true` | Backdrop + panel; **page scroll locked** |
| Body loading | Host assigns | Skeleton/spinner in body |
| Footer loading | Save in flight | Primary button loading |

#### Interactions

| Element | Action | Result |
|---------|--------|--------|
| Backdrop | click | `on_close` |
| Escape | keydown on overlay | `on_close` |
| Header close | click | `on_close` |
| Tab | keyboard | Cycles **within drawer only** (focus trap) |
| Footer Cancel | click | `on_close` |

#### Accessibility

- `role="dialog"`, `aria-modal="true"`
- `aria-labelledby` from header slot title id
- Close: `aria-label="Close drawer"`
- **Focus trap** while open (see §6b)
- **Body scroll lock** while open (see §6b)
- Escape closes; status not color-only

#### Copy hints

- Close: "Close drawer" (aria-label)
- Empty header slot: still expose close control

---

### Demo screen: Drawer showcase (prototype)

**Purpose:** Exercise all API variants with fixtures  
**Route:** `/bo/bo-drawer`  
**Entry:** BO sidebar (prototype section) or temporary nav link

#### Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│ Page header: Drawer component demo                                  │
├─────────────────────────────────────────────────────────────────────┤
│ Controls: placement select, size toggle, padding toggle, Open drawer  │
├─────────────────────────────────────────────────────────────────────┤
│ Sample list content (dimmed when drawer open)                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

### Reference screen: Agents — Create / Edit Agent

**Route:** `/bo/agents`  
**Default:** `placement: :right`, `size: :two_thirds`, `padding: :default`  
**Note:** Production migration deferred to `/design`; UX spec only here.

---

## 5. Component mapping

| UX need | Existing component | Gap? |
|---------|-------------------|------|
| Page shell | `BOLayout.bo_layout` | — |
| Drawer overlay | — | **`[NEW COMPONENT]`** `BODrawer.drawer/1` |
| Backdrop scrim | `.zaq-bo-modal-backdrop` | Reuse in `drawer.css` |
| Panel surface | `.zaq-modal` tokens | **`[GAP]`** drawer layout + slide classes |
| Header + close | `BOModal.modal_header/1` pattern | Adapt for drawer |
| Footer actions | `.zaq-modal-form-footer` / `.zaq-modal-form-actions` | Reuse |
| Focus trap + scroll lock | — | **`[NEW COMPONENT]`** `phx-hook="DrawerOverlay"` or shared `DialogOverlay` hook |
| Primary / secondary buttons | `DesignSystem.Button` | — |

---

## 5b. Form field mapping — Agents drawer body (reference)

| Screen | Field | Control (module) | Gap? |
|--------|-------|------------------|------|
| Create/Edit Agent | Name | `DesignSystem.Input` | migrate from raw input |
| Create/Edit Agent | Strategy | `ZaqWeb.Select` | — |
| Create/Edit Agent | Description | textarea / `DesignSystem.Input` | — |
| Create/Edit Agent | Job prompt | textarea | — |
| Create/Edit Agent | Credential | `ZaqWeb.Select` | — |
| Create/Edit Agent | Model | `ZaqWeb.Select` / `SearchableSelect` | — |
| Create/Edit Agent | MCP / tools / skills | custom panels + `BOModal.form_dialog` | — |
| Create/Edit Agent | Advanced / idle / memory | inputs | — |
| Create/Edit Agent | Conversation / Active | toggles | — |

Footer: Cancel (`on_close`), Save (submit), Delete (edit, tertiary danger).

---

## 6. UX decisions log

| Decision | Rationale |
|----------|-----------|
| Parent owns `is_open` | Matches `PortalConsentModal.show` / `BOModal` conditional render |
| All four placements in MVP | User requirement; demo page validates each |
| 1/3 & 2/3 height for top/bottom | Symmetric API with width sizes |
| Agents default **2/3** width | Matches current `MasterDetailLayout` detail pane proportion |
| Reuse modal backdrop | Visual consistency (`modal.css`) |
| Header/footer slots + mandatory close | Uniform chrome |
| Focus trap + scroll lock in MVP | Proper dialog a11y; see §6b |

---

## 6b. Focus trap and body scroll lock (a11y)

### What they are

**Focus trap:** While the drawer is open, keyboard focus (Tab / Shift+Tab) stays inside the drawer panel. Users cannot tab into the dimmed page behind the overlay. On open, focus moves into the drawer (typically the title or first field). On close, focus returns to the control that opened the drawer.

**Body scroll lock:** While the drawer is open, scrolling (mouse wheel, trackpad, touch) affects the drawer body only—not the page underneath. Prevents the list from scrolling while the user reads or fills the form.

### Why they matter

These behaviors follow the [WAI-ARIA APG modal dialog pattern](https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/). Without them:

- Screen-reader and keyboard users can interact with hidden content behind the overlay.
- Sighted users can accidentally scroll the list while the drawer appears active, causing disorientation.
- Focus can "escape" to the browser chrome or lost elements after close.

### Current ZAQ state

`BOModal.form_dialog` sets `role="dialog"` and `aria-modal="true"` but does **not** implement focus trap or body scroll lock today. Escape and backdrop close work; tab order is not constrained.

### Decision for drawer MVP

| Behavior | Drawer MVP | Rationale |
|----------|------------|-----------|
| Focus trap | **Yes** | Drawer is full-viewport overlay; higher risk of focus escape than centered modal |
| Body scroll lock | **Yes** | Slide-over panels expose more background; scroll bleed is very noticeable |
| Return focus on close | **Yes** | Via `return_focus_id` or hook remembering trigger |
| Retrofit BOModal | **Deferred** | Drawer ships correct behavior; modals can adopt shared hook later |

**Implementation note (for `/prototype` and `/design`):** Shared `phx-hook` (e.g. `DialogOverlay`) on drawer root: trap focus, `document.body` overflow hidden while mounted, restore on destroy. No visual design impact.

---

## 7. UI Designer Brief

### Build order

1. `assets/css/drawer.css` — overlay, placement transforms, size modifiers, reuse `.zaq-bo-modal-backdrop`
2. `BODrawer.drawer/1` — shell, slots, `is_open` / `on_close`, `include: [:js]`
3. `DialogOverlay` JS hook — focus trap + scroll lock
4. Optional `BODrawer.form_drawer/1` — composed helper mirroring `BOModal.form_dialog`
5. Prototype demo at `/bo/bo-drawer`
6. Storybook ( `/design` ) — all placements/sizes

### Design system constraints

- Tokens: `--zaq-*` only; import `drawer.css` from `styles.css` like `modal.css`
- Backdrop: `.zaq-bo-modal-backdrop`
- Drawer counts as separate context for primary button rule

### Stories to add/update (`/design`)

- [ ] Drawer — right, 1/3 and 2/3
- [ ] Drawer — left, top, bottom
- [ ] Drawer — flush vs default padding
- [ ] Drawer — with header/footer slots

### Open for visual design

- [ ] Slide animation duration/easing
- [ ] Panel border radius on anchored edge (flush to viewport vs rounded inner corner)
- [ ] z-index stack: drawer vs modal vs sidebar

### Prototype handoff

**`/prototype`** implements §5 on `/bo/bo-drawer` with fixtures-only state. Agents migration is **`/design`** with real data.

- `BODrawer.drawer/1` + `drawer.css` + `DialogOverlay` hook
- Demo LiveView toggles placement, size, padding, open state
- No raw `<input>` unless §5b marks `[GAP]`

### Next step

Run **`/prototype`** on this plan → review at `/bo/bo-drawer` → **`/design`** for Storybook + Agents wiring.
