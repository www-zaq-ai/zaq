# Building BO (Back Office) Components

> **Styling, tokens, typography, buttons, forms, and component inventory:** see [`DESIGN.md`](../DESIGN.md). This file covers BO layout mechanics, flash, icons, shared modules outside `design_system/`, and the PR checklist.

Follow these rules whenever creating or editing any LiveView, component, or template under `lib/zaq_web/live/bo/` or `lib/zaq_web/components/`.

---

## Layout wrapper

Every BO LiveView template **must** open with `<ZaqWeb.Components.BOLayout.bo_layout>` and close with `</ZaqWeb.Components.BOLayout.bo_layout>`. No exceptions.

```heex
<ZaqWeb.Components.BOLayout.bo_layout
  current_user={@current_user}
  flash={@flash}
  page_title="My Page"
  current_path={@current_path}
  features_version={@features_version}
>
  <%!-- page content here --%>
</ZaqWeb.Components.BOLayout.bo_layout>
```

The LiveView must assign `current_path` (the request path string, e.g. `"/bo/my-page"`) so the sidebar highlights the active nav item correctly.

The content slot is `#bo-content`. Sidebar collapse is client-owned state, retained
by the main app's LiveView DOM callback across server patches. Viewport-filling
screens must account for a wrapping BO header rather than assume it stays 56px
high. Mobile chat uses the remaining flex height, stacks its compact scrollable
conversation list above the chat, and allows chat header controls to wrap.

---

## Card pattern

Standard BO content cards follow this shell (see `DESIGN.md` for tokens):

```heex
<div class="zaq-card-default">
  <%!-- content --%>
</div>
```

Use `BOLayout.diagnostic_card/1`, `BOLayout.config_row/1`, and `BOLayout.feature_gate/1` for common card sub-patterns rather than reimplementing them inline. See `lib/zaq_web/components/bo_layout.ex` for their attr signatures.

---

## Icons

- Use `<.icon name="hero-x-mark" class="zaq-icon-sm"/>` for general inline icons (default 16px — see `DESIGN.md`).
- For larger icons use `class="zaq-icon-md"` (24px) when the role needs more prominence.
- Use `<ZaqWeb.Components.IconRegistry.icon namespace="nav" name="..." class="..."/>` for sidebar nav icons.
- Never import or call `Heroicons.*` modules directly.
- Do not use Tailwind size utilities (`w-5`, `h-5`) when a `.zaq-icon-*` class fits.

---

## Flash messages

Flash is handled by the `bo_layout` wrapper — do **not** render `<.flash_group>` inside a BO template. Pass `flash={@flash}` to the layout and let it render the info/error banners.

---

## Shared components — always reuse, never reimplement

Before writing any markup from scratch, check **`DESIGN.md` component inventory**, Storybook, and the modules below.

### `ZaqWeb.Components.DesignSystem.*` — preferred for new work

Buttons, links, inputs, modals, badges, cards, and navigation — see **`DESIGN.md` § Design system component inventory**. Use `DesignSystem.Button`, not `<.button>` from core components.

### `ZaqWeb.Components.BOLayout` — `lib/zaq_web/components/bo_layout.ex`

| Component | When to use |
|---|---|
| `<BOLayout.bo_layout>` | Wraps every BO page — sidebar, header, flash |
| `<BOLayout.diagnostic_card>` | Service / connection card with a status badge and optional test button |
| `<BOLayout.config_row>` | Single label ↔ value row with an optional inline hint tooltip |
| `<BOLayout.status_badge>` | Inline pill: `idle`, `loading`, `ok`, or `{:error, msg}` |
| `<BOLayout.feature_gate>` | Full-page "Feature Not Enabled" gate with a link to `/bo/addons` |

### `ZaqWeb.Components.BOModal` — `lib/zaq_web/components/bo_modal.ex`

Modal **shell** — feature content often lives in `DesignSystem.Modal*`. Use:

| Component | When to use |
|---|---|
| `<BOModal.modal_shell>` | Generic modal shell — pass any content via `inner_block` |
| `<BOModal.confirm_dialog>` | Standard delete / destructive-action confirmation dialog |
| `<BOModal.form_dialog>` | Add/edit popins with max-height and internal scroll |

### `ZaqWeb.Components.Drawer` — `lib/zaq_web/components/drawer.ex`

Drawer **shell** for slide-over create/edit flows (e.g. Agents). Parent owns `is_open`; no internal open state.

| Component | When to use |
|---|---|
| `<Drawer.drawer>` | Low-level shell — `:header`, body, and `:footer` slots |
| `<Drawer.form_drawer>` | Create/edit drawer with title header and footer actions slot |

Attributes: `placement` (`:left` \| `:right` \| `:top` \| `:bottom`), `size` (`:one_third` \| `:two_thirds`), `padding` (`:default` \| `:flush`), `on_close` (event string or `%JS{}`), optional `return_focus_id`. Uses `DialogOverlay` hook for focus trap and scroll lock.

### `ZaqWeb.Components.BOTelemetryComponents` — chart-heavy telemetry pages

| Component | When to use |
|---|---|
| `<BOTelemetryComponents.metric_card>` | KPI tile **with charts/telemetry** on metrics LiveViews |
| `<BOTelemetryComponents.time_series_chart>` | Line chart for time-series data |
| `<BOTelemetryComponents.bar_chart>` | Bar chart |
| `<BOTelemetryComponents.donut_chart>` | Donut / pie chart |
| `<BOTelemetryComponents.gauge_chart>` | Single-value gauge |
| `<BOTelemetryComponents.status_grid>` | Grid of status indicators |
| `<BOTelemetryComponents.progress_countdown>` | Progress bar with countdown |
| `<BOTelemetryComponents.radar_chart>` | Radar / spider chart |

For generic KPI tiles without telemetry chrome, prefer **`DesignSystem.MetricCard`** (`DESIGN.md`).

### Other shared modules under `lib/zaq_web/components/`

For reusable page-first bulk selection, see [Filter-scoped list selection](list-selection.md).
It covers the pure state helper, DS component, parent event contract, accessibility,
and server-side frozen confirmation pattern used by People.

| Module | When to use |
|---|---|
| `MasterDetailLayout` | Two-pane list + detail layout |
| `SearchableSelect` | Filterable dropdown with optional inline create |
| `ZaqWeb.Select` | Standard select (see `DESIGN.md`) |
| `RoleSharePicker` | Multi-select role assignment UI |
| `PasswordPolicyComponents` | Inline password-strength checklist |
| `FilePreview` / `FilePreviewModal` | File metadata and preview panel/modal |
| `ServiceUnavailable` | Full-page OTP node unavailable fallback |
| `ConnectCredentialForm` | Credential connection flows |
| `ChannelCapabilities` | Channel capability configuration UI |

### Ingestion file browser watch UI

Use the ingestion design-system components rather than reimplementing watch badges or row controls:

- `ZaqWeb.Components.DesignSystem.IngestionFileStatus` renders ingestion and watch status, including `pending`, `watched`, `error`, and inherited folder watch state.
- `ZaqWeb.Components.DesignSystem.IngestionFileListView` and `IngestionFileGridView` pass watch status through to each file/folder row or card.
- Provider watch errors open the LiveView retry/error modal; do not surface raw provider errors inline outside the shared status affordance.
- Inherited watch state is display-only for descendants. Users should clear or retry the directly watched parent folder instead of toggling a child inherited row.

### Manual label management

`/bo/labels` follows Teams catalog and name/description form interactions using
current design-system controls. The catalog uses streams and pages of 50 labels;
typing and opening an already-loaded row use cached state. Definitions are saved
through Ingestion Events rather than direct domain calls from BO.

Managers can delete a definition using the table's trash icon or the edit modal's
Delete label button. Both use `BOModal.confirm_dialog` with fresh document/chunk
usage counts. Changed usage or definition revision requires reconfirmation.
Cancel returns to unsaved edits; confirmed deletion preserves the resources.
The catalog also uses ingestion-style row and select-all checkboxes. Selection
is scoped to the current page and clears on search, pagination, or catalog reload.
Delete selected previews usage per label and deletes the batch atomically;
changed definitions or usage require reconfirming the entire batch.
Selection changes refresh streamed rows from the cached page so row checkboxes
stay synchronized with the header. Managers open editing by clicking a row or
the keyboard-accessible label name. Trash actions appear on row hover/focus.
Bulk confirmation uses the modal's optional `details` slot for a bounded,
scrollable usage table. Unused labels show “Not assigned”; errors appear separately
above the list, while confirmation actions remain outside the scroll region.

The Values / usage column opens `Components.LabelValueManager` inside the shared
viewport-bounded modal. It lists searchable value groups, including Empty value,
and readable document/chunk usage. Choosing a value lists matching resources;
read-only rows cannot be selected. Selection is limited to the visible 50-row page
and resets on navigation or reload. A proposed replacement (blank to clear) is
reviewed with the selected count before Save. Errors retain the proposal and
offer an explicit reload; saving refreshes the catalog counts. Clearing retains
the label assignment. The component uses `LabelEvents` and the existing DSM
table, input and button primitives, with no separate values catalog.

`DesignSystem.LabelChips` composes existing table badges and editor controls.
`DesignSystem.LabelEditor` composes `BOModal.form_dialog`, inputs and buttons with
the Share modal's staging/Save/Cancel interaction. `Components.LabelEditor` owns
the reusable LiveComponent state for typed document/chunk resources: changes are
local until Save, failures preserve staging, and Reload explicitly refreshes
versions. Parents handle `close_label_editor` and
`{:resource_labels_saved, resource}`. A LiveComponent keeps this state and event
contract identical across entry points. Current ingestion list/grid rows supply
document entry points; inline chunk entry points arrive in a later PR.

Each selected label uses the shared `SearchableSelect` with suggestions from
readable documents/chunks. Users can pick a saved value or add a new one; value
changes remain staged until Save. Chips render `Name: Value`, falling back to the
name for legacy assignments without values. Values are limited to 200 characters.
The selector's optional `target` and `event_context` route search/create events
to the owning LiveComponent and label. Existing consumers retain parent-LiveView
routing. The label picker opts into creation when no exact option matches.

Automatic controls are disabled in this delivery. Storybook's ingestion label
editor page provides the shared presentation fixture. Teams, Roles and Share
components retain their existing behavior and styling.

### Core components — legacy for non-BO or gradual migration

Auto-imported via `use ZaqWeb, :html` — **`core_components.ex`**. Prefer **`DesignSystem.*`** for new BO work.

| Component | Notes |
|---|---|
| `<.input>` | Legacy form inputs — use `DesignSystem.Input` in BO |
| `<.secret_input>` | Legacy — use `DesignSystem.SecretInput` in BO |
| `<.button>` | **Legacy daisyUI** — use `DesignSystem.Button` in BO |
| `<.table>` | Data tables — prefer `.zaq-table` patterns (`DESIGN.md`) |
| `<.icon name="hero-*">` | Heroicons wrapper — pair with `.zaq-icon-sm` / `.zaq-icon-md` |

---

## Common Pitfalls

### Raw `<input>` text color must be explicit

Raw `<input>` tags have no explicit text color in this codebase, so they inherit `color` from the parent chain. If any ancestor sets `color` to the accent (common in BO cards and badges), the input value text will render in that accent blue — readable against a dark background, illegible on white.

Always add `text-[var(--zaq-color-ink)]` to raw text inputs:

```heex
<%!-- Wrong: inherits color from parent, may render in accent blue --%>
<input type="text" class="w-full font-mono text-[0.82rem] border ..." />

<%!-- Correct --%>
<input type="text" class="w-full font-mono text-[0.82rem] text-[var(--zaq-color-ink)] border ..." />
```

Prefer `<.input>` over raw `<input>` — it applies the correct text color automatically.

---

### `SearchableSelect` inside modals — panel uses `position: fixed`

`BOModal.form_dialog` has `overflow-hidden` on the card and `overflow-y-auto` on the body. Both create overflow contexts that clip `position: absolute` children. The `SearchableSelect` JS hook works around this by switching the dropdown panel to `position: fixed` anchored to the trigger's viewport rect — so the panel always renders on top of everything, including modals.

This is handled automatically by the hook. You do not need to do anything special — just use `<.searchable_select>` inside a modal as normal.

**If you add a new JS-based dropdown or popover component** that uses `position: absolute`, be aware that it will be clipped by modal overflow. Apply the same `position: fixed` + `getBoundingClientRect()` pattern used in the `SearchableSelect` hook (`assets/js/app.js`).

---

### Checkbox color: `accent-*` not `text-*`

Native `<input type="checkbox">` ignores the CSS `color` property. The checkmark and fill color are controlled by the CSS `accent-color` property, which Tailwind exposes as `accent-*` utilities.

```heex
<%!-- Wrong: text-* has no effect on checkboxes --%>
<input type="checkbox" class="text-[var(--zaq-color-accent)]" />

<%!-- Correct --%>
<input type="checkbox" class="accent-[var(--zaq-color-accent)]" />
```

Prefer `<.input type="checkbox" ...>` over raw `<input>` tags — the core component applies the correct styling automatically.

---

## Checklist before opening a PR for any BO UI change

- [ ] Template opens with `<ZaqWeb.Components.BOLayout.bo_layout ...>` and `current_path` is assigned
- [ ] Styling follows [`DESIGN.md`](../DESIGN.md) (tokens, typography, buttons, forbidden patterns)
- [ ] No hardcoded hex, rgb, oklch, or hsl color values in templates
- [ ] No Tailwind color or typography classes (`text-sm`, `bg-white`, `font-mono`, etc.)
- [ ] No classes from `app.css` (`.zaq-bg-ink`, `.zaq-text-accent`, etc.)
- [ ] Buttons use `DesignSystem.Button` or documented `.zaq-btn-*` variants (not daisyUI `<.button>`)
- [ ] At most one `.zaq-btn-primary` per LiveView content area (modals/drawers excluded)
- [ ] New cards use `zaq-card-default`
- [ ] Icons use `<.icon>` or `IconRegistry.icon` with `.zaq-icon-sm` / `.zaq-icon-md`
- [ ] Checkboxes use `accent-[var(--zaq-color-accent)]`, not `text-[var(--zaq-color-accent)]` — or use `<.input type="checkbox">`
- [ ] Raw `<input type="text">` tags have `text-[var(--zaq-color-ink)]` — or use `<.input>`
- [ ] No `<.flash_group>` in the template
- [ ] [Feature E2E approval gate](testing-approach.md#feature-e2e-approval-gate) respected: iterative PRs link the current E2E issue and approval blocker (or explain why E2E is unnecessary); finalization records human UX/UI approval and passing required E2E
- [ ] Any existing E2E repairs are minimal and preserve assertions and intent, without weakening them to hide regressions
- [ ] `mix q` passes
