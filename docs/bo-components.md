# Building BO (Back Office) Components

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

---

## Styling Priority

Apply styles in this exact order. Later steps are only acceptable if earlier steps are impossible.

1. **Use an existing class** from `styles.css`, `semantics.css`, `text-styles.css`, or `btn.css`.
   - Classes in `app.css` are **off-limits** — they are legacy/deprecated.
2. **Buttons** — always use `.zaq-btn-primary` or `.zaq-btn-secondary` from `btn.css`.
   No new button styles. No daisyUI button classes.
3. **Text** — always use the closest `.zaq-text-*` class from `text-styles.css`.
   No Tailwind text sizing (`text-sm`, `text-lg`, `text-[*]`). No inline font vars.
   Text decorations (`uppercase`, `underline`, `tracking-*`) are acceptable alongside a `.zaq-text-*` base.
4. **New class needed** → add a new semantic utility class to `styles.css` only. Never `app.css`.
5. **No class fits** → use a semantic var inline:
   `--zaq-surface-color-*`, `--zaq-text-color-*`, or `--zaq-border-color-*`.
   Never foundation vars (`--zaq-color-blue-*`, `--zaq-color-neutral-*`, `--zaq-color-black-*`).
6. **Tailwind** → fallback for layout and spacing only. Never color. Never typography.

### Text style mapping

| Role | Class |
|---|---|
| Page/section heading | `.zaq-text-h1` → `.zaq-text-h5` |
| Body copy (large) | `.zaq-text-body-lg` |
| Body copy (default) | `.zaq-text-body` |
| Body copy (small), table content | `.zaq-text-body-sm` |
| Meta / supporting / compact labels | `.zaq-text-caption` |
| Code / monospace | `.zaq-text-code` |
| Pre-formatted block | `.zaq-text-pre` |
| Button label | `.zaq-btn-text_label-default` (inside buttons only) |

When ambiguous between adjacent scales, prefer the smaller one. Map by visual role, not pixel size.

### Forbidden patterns

- Any class from `app.css` (`.zaq-bg-ink`, `.zaq-text-accent`, `.zaq-bg-accent-soft`, etc.)
- Hardcoded hex, rgb, oklch, or hsl color values in templates
- Foundation vars in templates (`var(--zaq-color-blue-400)`, `var(--zaq-color-neutral-*)`)
- Tailwind color or typography classes (`text-gray-600`, `bg-white`, `font-mono`, `text-sm`)
- daisyUI component classes in BO templates

## Design tokens (deprecated)

The `--zaq-color-*` variables and the utility classes below are the old token system defined in `app.css`. Do not use them in new components. Do not add new classes to `app.css`.

| Token | Legacy use |
|---|---|
| `var(--zaq-color-accent)` | Primary actions, active states, links |
| `var(--zaq-color-accent-hover)` | Hover on accent elements |
| `var(--zaq-color-accent-soft)` | Subtle accent backgrounds |
| `var(--zaq-color-ink)` | Body text, sidebar background |
| `var(--zaq-color-ink-soft)` | Secondary / muted text |
| `var(--zaq-color-surface)` | Page background |
| `var(--zaq-color-surface-border)` | Card / divider borders |

Legacy utility classes from `app.css` (do not use in new components):

```
zaq-bg-ink          zaq-bg-accent         zaq-bg-accent-soft
zaq-text-ink        zaq-text-ink-soft     zaq-text-accent
zaq-border-accent   zaq-border-accent-soft
```

---

## Typography

Use `.zaq-text-*` classes from `text-styles.css` — see the Text style mapping table in the Styling Priority section above. Do not use `font-mono`, Tailwind text-sizing utilities, or inline font vars.

Decorative modifiers (`uppercase`, `tracking-widest`, `underline`) are acceptable alongside a `.zaq-text-*` base class when the role calls for them (e.g. sidebar section labels).

---

## Card pattern

Standard BO content cards follow this shell:

```heex
<div class="zaq-card-default">
  <%!-- content --%>
</div>
```

Use `BOLayout.diagnostic_card/1`, `BOLayout.config_row/1`, and `BOLayout.feature_gate/1` for common card sub-patterns rather than reimplementing them inline. See `lib/zaq_web/components/bo_layout.ex` for their attr signatures.

---

## Buttons

- **Primary action**: use `.zaq-btn-primary` from `btn.css`.
- **Secondary action**: use `.zaq-btn-secondary` from `btn.css`.
- **Destructive / danger**: use `.zaq-btn-danger` from `btn.css`, documented in the **Danger** section of that file. For ingestion-style toolbar chips, compose `.zaq-btn` + `.zaq-btn-tertiary` + `.zaq-btn-danger` (internal tokens: `--zaq-btn-danger-*`). Do not write one-off Tailwind button styles.
- Never use daisyUI button classes. Never hand-roll button styles with `font-mono`, `zaq-bg-accent`, or `bg-red-*`.

---

## Icons

- Use `<.icon name="hero-x-mark" class="w-5 h-5"/>` (Heroicons via `core_components.ex`) for general icons.
- Use `<ZaqWeb.Components.IconRegistry.icon namespace="nav" name="..." class="..."/>` for sidebar nav icons.
- Never import or call `Heroicons.*` modules directly.

---

## Flash messages

Flash is handled by the `bo_layout` wrapper — do **not** render `<.flash_group>` inside a BO template. Pass `flash={@flash}` to the layout and let it render the info/error banners.

---

## Shared components — always reuse, never reimplement

Before writing any markup from scratch, check whether one of these components already covers the need.

### `ZaqWeb.Components.BOLayout` — `lib/zaq_web/components/bo_layout.ex`

| Component | When to use |
|---|---|
| `<BOLayout.bo_layout>` | Wraps every BO page — sidebar, header, flash |
| `<BOLayout.diagnostic_card>` | Service / connection card with a status badge and optional test button |
| `<BOLayout.config_row>` | Single label ↔ value row with an optional inline hint tooltip |
| `<BOLayout.status_badge>` | Inline pill: `idle`, `loading`, `ok`, or `{:error, msg}` |
| `<BOLayout.feature_gate>` | Full-page "Feature Not Enabled" gate with a link to `/bo/addons` |

### `ZaqWeb.Components.BOModal` — `lib/zaq_web/components/bo_modal.ex`

| Component | When to use |
|---|---|
| `<BOModal.modal_shell>` | Generic modal shell — pass any content via `inner_block` |
| `<BOModal.confirm_dialog>` | Standard delete / destructive-action confirmation dialog |

### `ZaqWeb.Components.BOTelemetryComponents` — `lib/zaq_web/components/bo_telemetry_components.ex`

| Component | When to use |
|---|---|
| `<BOTelemetryComponents.metric_card>` | KPI tile with value, unit, trend, and hint |
| `<BOTelemetryComponents.time_series_chart>` | Line chart for time-series data |
| `<BOTelemetryComponents.bar_chart>` | Bar chart |
| `<BOTelemetryComponents.donut_chart>` | Donut / pie chart |
| `<BOTelemetryComponents.gauge_chart>` | Single-value gauge |
| `<BOTelemetryComponents.status_grid>` | Grid of status indicators |
| `<BOTelemetryComponents.progress_countdown>` | Progress bar with countdown |
| `<BOTelemetryComponents.radar_chart>` | Radar / spider chart |

### MasterDetailLayout — `lib/zaq_web/components/master_detail_layout.ex`

| Component | When to use |
|---|---|
| `<MasterDetailLayout.master_detail>` | Two-pane layout (list on left, detail on right) — collapses master when detail is open |

### SearchableSelect — `lib/zaq_web/components/searchable_select.ex`

| Component | When to use |
|---|---|
| `<SearchableSelect.searchable_select>` | Filterable dropdown with optional inline create; use instead of a plain `<select>` whenever the option list may be long |

### `ZaqWeb.Components.RoleSharePicker` — `lib/zaq_web/components/role_share_picker.ex`

| Component | When to use |
|---|---|
| `<RoleSharePicker.role_share_picker>` | Multi-select role assignment UI |

### PasswordPolicyComponents — `lib/zaq_web/components/password_policy_components.ex`

| Component | When to use |
|---|---|
| `<PasswordPolicyComponents.password_requirements>` | Inline password-strength requirement checklist |

### Core components (auto-imported via `use ZaqWeb, :html`) — `lib/zaq_web/components/core_components.ex`

| Component | When to use |
|---|---|
| `<.input>` | All form inputs (text, select, textarea, checkbox) |
| `<.secret_input>` | Password / token / API key fields — includes eye-toggle, never inline it |
| `<.button>` | Standard form submit button |
| `<.table>` | Data tables |
| `<.list>` | Definition-style key/value lists |
| `<.header>` | Section headers with optional subtitle and actions slot |
| `<.icon name="hero-*">` | Heroicons — the only approved icon method |

### `ZaqWeb.Components.ServiceUnavailable` — `lib/zaq_web/components/service_unavailable.ex`

| Component | When to use |
|---|---|
| `<ServiceUnavailable.page>` | Full-page "service node unavailable" fallback when a required OTP node is down |

### `ZaqWeb.Components.FilePreview` — `lib/zaq_web/components/file_preview.ex`

| Component | When to use |
|---|---|
| `<FilePreview.meta>` | File metadata summary (name, size, type) |
| `<FilePreview.panel>` | Inline file preview panel (PDF, image, text) |

---

## Checklist before opening a PR for any BO UI change

- [ ] Template opens with `<ZaqWeb.Components.BOLayout.bo_layout ...>` and `current_path` is assigned
- [ ] No hardcoded hex, rgb, oklch, or hsl color values in templates
- [ ] No `font-mono`, `text-sm`, `text-[*]`, `bg-white`, or other Tailwind color/typography classes
- [ ] No classes from `app.css` (`.zaq-bg-ink`, `.zaq-text-accent`, `.zaq-bg-accent-soft`, etc.)
- [ ] All text uses a `.zaq-text-*` class from `text-styles.css`
- [ ] All buttons use `.zaq-btn-primary` or `.zaq-btn-secondary` from `btn.css`
- [ ] New cards use `zaq-card-default` (not `bg-white border-black/10`)
- [ ] Icons use `<.icon>` or `IconRegistry.icon`, not `Heroicons.*`
- [ ] No `<.flash_group>` in the template
- [ ] `mix precommit` passes
