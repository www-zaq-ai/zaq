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

## Design tokens — always use CSS variables, never hardcode colors

| Token | Value | Use for |
|---|---|---|
| `var(--zaq-color-accent)` | `#03b6d4` | Primary actions, active states, links |
| `var(--zaq-color-accent-hover)` | `#029ab3` | Hover on accent elements |
| `var(--zaq-color-accent-soft)` | `rgba(3,182,212,0.10)` | Subtle accent backgrounds |
| `var(--zaq-color-ink)` | `#2c3a50` | Body text, sidebar background |
| `var(--zaq-color-ink-soft)` | `#5c5a55` | Secondary / muted text |
| `var(--zaq-color-surface)` | `#faf9f7` | Page background |
| `var(--zaq-color-surface-border)` | `#e8e6e1` | Card / divider borders |

Prefer the utility classes defined in `assets/css/app.css` over raw `var(...)` where one exists:

```
zaq-bg-ink          zaq-bg-accent         zaq-bg-accent-soft
zaq-text-ink        zaq-text-ink-soft     zaq-text-accent
zaq-border-accent   zaq-border-accent-soft
```

---

## Typography

- **All text in BO uses `font-mono`** (maps to `var(--zaq-font-primary)` — ZAQ Sans / Roboto).
- Common size scale: labels `text-[0.7rem]`, body `text-[0.82rem]`, page title `text-lg font-bold`.
- Section labels in the sidebar use `text-[0.58rem] uppercase tracking-widest`.

---

## Card pattern

Standard BO content cards follow this shell:

```heex
<div class="bg-white rounded-xl border border-black/10 p-5">
  <%!-- content --%>
</div>
```

Use `BOLayout.diagnostic_card/1`, `BOLayout.config_row/1`, and `BOLayout.feature_gate/1` for common card sub-patterns rather than reimplementing them inline. See `lib/zaq_web/components/bo_layout.ex` for their attr signatures.

---

## Buttons

- **Primary action**: `font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg zaq-bg-accent text-white hover:bg-[var(--zaq-color-accent-hover)] transition-colors`
- **Secondary / ink**: `font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg zaq-bg-ink text-white hover:opacity-80 transition-colors`
- **Destructive**: replace background with `bg-red-600 hover:bg-red-700`
- Never use daisyUI. Always write Tailwind classes manually.

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
| `<BOLayout.feature_gate>` | Full-page "Feature Not Licensed" gate with a link to `/bo/license` |

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
- [ ] No hardcoded hex colors — use CSS variables or utility classes
- [ ] All text uses `font-mono` (or inherits it from the layout)
- [ ] New cards follow the `bg-white rounded-xl border border-black/10` pattern
- [ ] Icons use `<.icon>` or `IconRegistry.icon`, not `Heroicons.*`
- [ ] No `<.flash_group>` in the template
- [ ] `mix precommit` passes
