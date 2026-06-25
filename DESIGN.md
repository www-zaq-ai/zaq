---
version: alpha
name: ZAQ Design System
description: AI-powered company brain — back-office UI. Functional and clear, with a signature neon brand moment on primary actions.
source_of_truth: "CSS files in assets/css/ (foundations → semantics → role files). This document is the human + AI guide; when in conflict, CSS wins."
colors:
  # Shorthand labels below map to --zaq-* semantic vars — see Token naming table in body.
  surface-base: "#fafafa"       # --zaq-surface-color-base
  surface-raised: "#ffffff"     # --zaq-surface-color-raised
  surface-elevated: "#e2e8f0"   # --zaq-surface-color-elevated
  surface-accent: "#e6f8fb"     # --zaq-surface-color-accent
  surface-danger: "#FFFAFA"     # --zaq-surface-color-danger
  surface-success: "#EFFFFD"    # --zaq-surface-color-success
  surface-warning: "#fffbf0"    # --zaq-surface-color-warning
  text-default: "#0C1324"       # --zaq-text-color-body-default
  text-secondary: "#293442"     # --zaq-text-color-body-secondary
  text-tertiary: "#43536d"      # --zaq-text-color-body-tertiary
  text-invert: "#ffffff"        # --zaq-text-color-body-invert
  text-accent: "#027589"        # --zaq-text-color-body-accent
  text-danger: "#B70030"        # --zaq-text-color-body-danger
  text-success: "#007C6B"       # --zaq-text-color-body-success
  text-warning: "#843f00"       # --zaq-text-color-body-warning
  border-default: "#e2e8f0"     # --zaq-border-color-default
  border-strong: "#acb3bd"      # --zaq-border-color-strong
  border-accent: "#03b6d4"      # --zaq-border-color-accent
  border-danger: "#ea003e"      # --zaq-border-color-danger
  border-success: "#00baa6"     # --zaq-border-color-success
  border-warning: "#df6f00"     # --zaq-border-color-warning
  neon-start: "#0aadca"         # --zaq-color-neon-start (button gradient only)
  neon-mid: "#3dd5ee"           # --zaq-color-neon-mid
  neon-end: "#00d492"           # --zaq-color-neon-end
typography:
  h1: { fontFamily: Hanken Grotesk, fontSize: 24px, fontWeight: 600, lineHeight: 1.4 }
  h2: { fontFamily: Hanken Grotesk, fontSize: 20px, fontWeight: 600, lineHeight: 1.2 }
  h3: { fontFamily: Hanken Grotesk, fontSize: 16px, fontWeight: 600, lineHeight: 1.2 }
  h4: { fontFamily: Hanken Grotesk, fontSize: 14px, fontWeight: 600, lineHeight: 1.2 }
  h5: { fontFamily: Hanken Grotesk, fontSize: 12px, fontWeight: 600, lineHeight: 1.2 }
  body-lg: { fontFamily: Inter, fontSize: 16px, fontWeight: 400, lineHeight: 1.6 }
  body: { fontFamily: Inter, fontSize: 14px, fontWeight: 400, lineHeight: 1.6 }
  body-sm: { fontFamily: Inter, fontSize: 12px, fontWeight: 400, lineHeight: 1.6 }
  caption: { fontFamily: Inter, fontSize: 10px, fontWeight: 400, lineHeight: 1.6, letterSpacing: 0.05em }
  code: { fontFamily: JetBrains Mono, fontSize: 12px, fontWeight: 400, lineHeight: 1.6 }
  pre: { fontFamily: JetBrains Mono, fontSize: 14px, fontWeight: 400, lineHeight: 1.6 }
spacing:
  # Layout scales — safe for padding, margin, gap, width, height, border-radius
  layout: [0, 2, 4, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 120]
  # Text-only scales — font-size via .zaq-text-* classes ONLY; never for layout
  text_only: [10, 12, 14, 20]
  # Special-purpose
  special: { "1": "border thickness", "999": "pill radius", "1440": "desktop max-width" }
rounded:
  sm: 8px    # --zaq-btn-all-radius-default
  md: 16px   # --zaq-card-radius-default
  pill: 999px # --zaq-btn-all-radius-pill
---

# ZAQ Design System

## Overview

ZAQ is an AI-powered company brain — the back-office (BO) is the primary interface used by knowledge workers and administrators. The visual language is **functional-first with a confident brand moment**: clean surfaces, high-contrast ink, and a signature animated neon gradient reserved exclusively for the primary CTA. The UI should feel focused and professional without being sterile. The neon accent is a product signature, not decoration — it signals interactive energy.

Target users: internal operators, knowledge managers, and IT admins. The UI must support dense information layouts while remaining legible and accessible (WCAG AA minimum).

**Source of truth (in priority order):**

1. CSS files in `assets/css/` — foundations → semantics → role-specific files
2. Storybook stories — visual contract for components and patterns
3. This document — intent, naming, and agent rules
4. YAML frontmatter above — quick reference only; never override CSS

**Companion docs:**

- `docs/bo-components.md` — BO operational rules only (BOLayout, flash, shared modules, PR checklist). **Not** the styling source of truth.
- `.claude/skills/design/SKILL.md` — agent entry point for new BO UI
- `/extract` — copy inline UI into `DesignSystem.*` modules
- `/design-migrate` — token enforcement and migration workflow
- `/replace` — wire existing components into LiveViews (human confirmation)

**When uncertain:** Storybook → role CSS file (see catalog below) → `/design-migrate` constraints → ask a human.

### Agent workflow

Human confirmation is required at the validation gate of each skill (extraction report, migration table, replacement report).

**Typical order:**

```
extract  →  design-migrate  →  replace
```

| Step | Skill | What it does |
|------|-------|--------------|
| 1 | **extract** | Copy inline UI into `lib/zaq_web/components/design_system/` + Storybook. Source LiveViews stay unchanged. |
| 2 | **design-migrate** | Apply `--zaq-*` tokens to the extracted module and/or target files. |
| 3 | **replace** | Wire approved components into LiveViews; remove duplicate inline markup. |

Skip steps that do not apply (e.g. migrate-only on an existing file, replace not needed when extract was extend-only).

**Component decision tree:**

| Need | Use |
|------|-----|
| Page shell, sidebar, flash | `BOLayout.bo_layout` |
| Buttons, links, inputs, badges, empty states | `DesignSystem.*` (see inventory below) |
| Modal shell (backdrop, panel, confirm) | `BOModal.*` — feature bodies often in `DesignSystem.Modal*` |
| KPI tile (generic) | `DesignSystem.MetricCard` |
| KPI + charts on telemetry pages | `BOTelemetryComponents.metric_card` |
| Long option lists | `SearchableSelect` |
| Master/detail layout | `MasterDetailLayout` |
| Legacy portal / non-BO forms | `core_components` (`<.input>`, `<.button>`) — migrate to `DesignSystem.*` in BO |

**CSS load order:** `form.css` and `modal.css` are imported from `styles.css` (not directly from `app.css`). Do not re-import them in templates.

---

## CSS file catalog

| File | Owns | Use in templates |
|---|---|---|
| `foundations.css` | Palette, fonts, raw `--zaq-scale-*` | Never — foundation vars are internal |
| `semantics.css` | `--zaq-surface-*`, `--zaq-border-*`, `--zaq-text-color-*`, `--zaq-layout-*`, shape tokens | Inline color/surface only (`var(--zaq-text-color-body-default)`, etc.) |
| `text-styles.css` | `.zaq-text-*`, scoped label classes | Always via class — never inline `font-size` |
| `btn.css` | `.zaq-btn-*`, internal `--zaq-btn-*` vars | Button classes only; never reference `--zaq-btn-*` outside this file |
| `form.css` | `.zaq-control-*`, `.zaq-field-*` | Form shells and field layout |
| `modal.css` | `.zaq-modal`, `.zaq-bo-modal-backdrop`, flush variant | Modal chrome |
| `table.css` | `.zaq-table` and cell patterns | Data tables and dense list grids |
| `layout.css` | `.zaq-layout-stack`, `.zaq-layout-inline`, gap modifiers | Role-based spacing utilities |
| `styles.css` | Cards, borders, feature patterns (`.zaq-chat-*`), generic BO chrome | Shared non-role primitives |
| `app.css` | Legacy — read reference only | **Do not use** |

---

## Token naming

Semantic tokens use role-based names. In templates, always use the full `--zaq-*` variable — never shorthand labels or foundation palette names.

| Shorthand (docs) | CSS variable | Allowed properties |
|---|---|---|
| `surface-base` | `--zaq-surface-color-base` | `background`, `background-color` |
| `surface-raised` | `--zaq-surface-color-raised` | background only |
| `surface-elevated` | `--zaq-surface-color-elevated` | background only |
| `surface-accent` | `--zaq-surface-color-accent` | background only |
| `surface-danger/success/warning` | `--zaq-surface-color-danger` etc. | background only |
| `text-default` | `--zaq-text-color-body-default` | `color` only |
| `text-secondary` | `--zaq-text-color-body-secondary` | color only |
| `text-tertiary` | `--zaq-text-color-body-tertiary` | color only — also used for input placeholders |
| `text-invert` | `--zaq-text-color-body-invert` | color only |
| `text-accent` | `--zaq-text-color-body-accent` | color only |
| `text-danger/success/warning` | `--zaq-text-color-body-danger` etc. | color only — WCAG-safe on feedback surfaces |
| `border-default` | `--zaq-border-color-default` | `border-color`, `outline-color` |
| `border-strong` | `--zaq-border-color-strong` | border/outline only |
| `border-accent` | `--zaq-border-color-accent` | border/outline only |
| `border-danger/success/warning` | `--zaq-border-color-danger` etc. | border/outline only |
| `icon-default` | `--zaq-icon-color-default` | `color`, `fill`, `stroke` on icons |
| `icon-accent` | `--zaq-icon-color-accent` | icon color only |

**Never in templates:** foundation vars (`--zaq-color-blue-*`, `--zaq-color-neutral-*`, `--zaq-color-black-*`), internal button vars (`--zaq-btn-*`), or shape tokens (`--zaq-card-*`, `--zaq-border-thickness-*`) — compose those via existing classes.

**Feedback naming:** use `danger`, not `error` (`--zaq-border-color-danger`, not `error`).

---

## Colors

Colors are defined at the **semantic layer** — names describe role, not palette position. Each token maps to a `--zaq-*` CSS custom property that resolves to a foundation color at runtime.

**Surfaces** — tonal layers convey depth without relying on shadows:

- `surface-base` — page background, lowest layer.
- `surface-raised` — cards, inputs, modals.
- `surface-elevated` — dropdowns, popovers, tooltips, tertiary button chrome.
- `surface-accent` — tinted accent fill (e.g. selected state backgrounds).
- `surface-danger / success / warning` — feedback surface tints, lightest possible.

**Text** — ink scale with explicit roles:

- `text-default` — primary body text, maximum contrast.
- `text-secondary` — supporting text, labels.
- `text-tertiary` — metadata, captions, muted UI chrome, **input placeholders**.
- `text-invert` — text on filled/dark backgrounds.
- `text-accent` — brand-colored links and accent labels.
- `text-danger / success / warning` — WCAG AA-safe for text and icons on feedback surfaces.

Disabled control text is handled per component via internal button/form tokens (typically `--zaq-color-black-100` / `--zaq-text-color-body-tertiary` depending on context) — there is no standalone `--zaq-text-color-body-disabled` semantic token yet.

**Borders:**

- `border-default` — standard dividers and control outlines.
- `border-strong` — stronger separation when needed.
- `border-accent` — focus rings and interactive hover borders.
- `border-danger / success / warning` — feedback border colors.

**Icons:**

- `icon-default` — neutral icon fill on light surfaces.
- `icon-accent` — brand-colored icons.

**Brand / Interactive:**

- Neon gradient stops (`--zaq-color-neon-start/mid/end`) — animated primary button background only. Never use these colors statically on other elements.
- `--zaq-gradient-neon` (135deg) — generic brand gradient reference in foundations; the primary **button** uses a separate 30deg animated gradient defined in `btn.css`.

---

## Typography

Two typefaces: **Hanken Grotesk** for headings (institutional, confident) and **Inter** for body and UI text (neutral, highly legible at small sizes). **JetBrains Mono** for code blocks only.

Each level maps directly to a CSS class in `text-styles.css`. Always use the class — never set `font-size`, `font-family`, or `line-height` inline.

- `.zaq-text-h1` — 24px Hanken Grotesk Semibold, line-height 1.4. Page-level titles.
- `.zaq-text-h2` — 20px Hanken Grotesk Semibold, line-height 1.2. Section headings.
- `.zaq-text-h3` — 16px Hanken Grotesk Semibold. Sub-section headings, card titles.
- `.zaq-text-h4` — 14px Hanken Grotesk Semibold. Dense headings, table column headers.
- `.zaq-text-h5` — 12px Hanken Grotesk Semibold. Smallest heading level, use sparingly.
- `.zaq-text-body-lg` — 16px Inter Regular, line-height 1.6. Large body copy.
- `.zaq-text-body` — 14px Inter Regular, line-height 1.6. Default body text for the BO.
- `.zaq-text-body-sm` — 12px Inter Regular. Secondary content, metadata.
- `.zaq-text-caption` — 10px Inter Regular, 0.05em letter-spacing. Timestamps, helper text, labels at minimum size.
- `.zaq-text-code` — 12px JetBrains Mono. Inline code only.
- `.zaq-text-pre` — 14px JetBrains Mono. Code blocks and preformatted output only.

Two scoped styles are not standalone classes:

- `.zaq-btn-text_label-default` — Inter Regular 12px. Scoped to `.zaq-btn` elements only.
- `.zaq-field-label-uppercase` — 10px Inter, uppercase, 0.05em tracking. Scoped to form field labels only.

---

## Spacing & scale tokens

The BO uses an **8px base grid** with a 4px half-step for micro-gaps. Scale tokens live in `foundations.css`; role-based layout tokens in `semantics.css`.

### Three scale roles (never mix)

| Role | Tokens | Allowed use |
|---|---|---|
| **Layout** | `--zaq-scale-0`, `2`, `4`, `8`, `16`, `24`, `32`, `40`, `48`, `56`, `64`, `72`, `80`, `88`, `96`, `120` | `padding`, `margin`, `gap`, `width`, `height`, `border-radius` — in CSS classes, not templates |
| **Text-only** | `--zaq-scale-10`, `12`, `14`, `20` | `font-size` only, via `.zaq-text-*` in `text-styles.css` — **never** for spacing |
| **Special** | `--zaq-scale-1` (border thickness), `--zaq-scale-999` (pill), `--zaq-scale-1440` (max-width) | Matching property only |

**No layout token at 12px or 20px.** Legacy Tailwind `gap-3` / `p-5` values converge to `--zaq-scale-16` or stay as one-off Tailwind until a reusable class exists.

### Layout role tokens

| Token | Value | Intent |
|---|---|---|
| `--zaq-layout-page-inset` | 32px | Outer padding of main content (`BOLayout`) |
| `--zaq-layout-page-bleed` | 32px | Full-bleed content under page chrome |
| `--zaq-layout-section-gap` | 24px | Between major page blocks, two-column grids |
| `--zaq-layout-stack-gap` | 16px | Vertical rhythm between sibling components |
| `--zaq-layout-stack-gap-tight` | 8px | Label-to-value pairs, dense lists |
| `--zaq-layout-inline-gap` | 8px | Toolbar controls, icon + label pairs |
| `--zaq-layout-inline-gap-compact` | 4px | Chip clusters, pill groups |
| `--zaq-layout-content-inset` | 24px | Inner column inset (e.g. chat transcript) |
| `--zaq-layout-grid-gap` | 16px | Card and metric grids |

### Page shell — `bo_layout` (mandatory)

Every BO page is wrapped in **`ZaqWeb.Components.BOLayout.bo_layout`** — the fixed-sidebar + scrollable main shell. No exceptions.

| | |
|---|---|
| Module | `lib/zaq_web/components/bo_layout.ex` |
| Component | `<.bo_layout>` / `<ZaqWeb.Components.BOLayout.bo_layout>` |
| Storybook | `storybook/layouts/bo_layout.story.exs` |

**Required assigns:** `current_user`, `flash`, `page_title`, `current_path` (request path for active nav), `features_version`.

Page content goes in the inner slot — never reimplement sidebar, header, or nav chrome in a LiveView. `--zaq-layout-page-inset` applies to the main content region inside this shell.

```heex
<ZaqWeb.Components.BOLayout.bo_layout
  current_user={@current_user}
  flash={@flash}
  page_title="My Page"
  current_path={@current_path}
  features_version={@features_version}
>
  <%!-- page content only — no sidebar or outer chrome --%>
</ZaqWeb.Components.BOLayout.bo_layout>
```

BO operational rules (flash, shared module index): `docs/bo-components.md`.

### Layout utilities (`layout.css`)

Prefer these over inline spacing:

- `.zaq-layout-stack` / `.zaq-layout-stack-tight` — vertical flex columns
- `.zaq-layout-inline` / `.zaq-layout-inline-compact` — horizontal clusters
- `.zaq-layout-section-gap` / `.zaq-layout-grid-gap` — gap modifiers on grid/flex containers
- `.zaq-layout-content-inset` — inner reading column padding

Desktop max-width is `--zaq-scale-1440` (1440px).

---

## Elevation & Depth

ZAQ uses **tonal layering** rather than shadows to convey depth:

- `surface-base` — page background, lowest layer.
- `surface-raised` — cards, inputs, modals; sits above the base.
- `surface-elevated` — dropdowns, tooltips, popovers; highest tonal layer.

Border presence signals interactivity, not depth. Cards gain `border-accent` on hover when `.zaq-card-hover` is a direct child of an interactive element. A subtle `box-shadow` may accompany raised surfaces but is never the primary depth signal.

---

## Shapes

Two radii in use:

- `--zaq-btn-all-radius-default` (8px) — buttons and interactive controls
- `--zaq-card-radius-default` (16px) — cards, blocks, inputs, modals

Tags, status badges, and secondary pill chips use `--zaq-btn-all-radius-pill` (999px). Pill shape (`.zaq-btn-pill`) composes with `.zaq-btn-secondary` only.

Do not mix sharp (0px) and rounded corners in the same view. Do not mix 8px and 16px radius on the **same element**.

---

## Icons

Use **Heroicons exclusively** via `hero-*` Tailwind utility classes (registered in `assets/vendor/heroicons.js`). Render with `<.icon name="hero-*" …/>` or `IconRegistry.icon/1`.

**Size:** use DS icon classes from `styles.css` — not Tailwind width/height utilities:

| Class | Size | When |
|-------|------|------|
| `.zaq-icon-sm` | `--zaq-scale-16` (16px) | **Default** — inline icons, breadcrumbs, toolbars, nav-adjacent controls |
| `.zaq-icon-md` | `--zaq-scale-24` (24px) | Prominent standalone icons or larger hit targets |

If neither fits the role, add a reusable class in `styles.css` using `--zaq-scale-16` or `--zaq-scale-24` only — do not use arbitrary pixel sizes.

Icon **color** follows semantic tokens: `--zaq-icon-color-default` for neutral, `--zaq-icon-color-accent` for brand emphasis (via `color` on the icon element or parent). Icon-only buttons require `aria-label` — see Buttons below.

---

## Components

> **Before building any UI element, consult Storybook** — it is the visual contract for every component, pattern, and foundation token. Stories show correct usage, all variants, and edge cases. If a story exists, match it exactly. If it doesn't, create one alongside the component.

### Storybook map

| Folder | Contents |
|---|---|
| `storybook/foundations/` | Color palette, typography, spacing, icons |
| `storybook/semantic/` | Semantic tokens — colors, text styles, borders, layout |
| `storybook/components/` | Atomic components — forms, cards, badges, navigation, icons, file preview, modals |
| `storybook/components/design_system/` | Canonical DS component stories (prefer these over duplicates) |
| `storybook/patterns/` | Composed patterns — upsell cards, credentials |
| `storybook/layouts/` | Page shells — **`bo_layout` is the mandatory BO page wrapper**; also app layout, master-detail |
| `storybook/modals/` + `storybook/bo_modal/` | Modal variants — prefer stories linked to `DesignSystem.*` modules |
| Feature folders (`chat/`, `dashboard/`, `history/`, `ingestion/`) | Feature-composed components |
| `storybook/playground/` | Experiments — not a contract |
| `storybook/legacy_ui/`, `storybook/not_used/` | Deprecated — do not reference or reuse |

### Buttons

> Canonical: `lib/zaq_web/components/design_system/button.ex` + `assets/css/btn.css` + `storybook/components/design_system/` button story.

Four variants in ascending visual weight: **tertiary → ghost → secondary → primary**.

| Variant | Class | Resting | Hover | Notes |
|---|---|---|---|---|
| **Primary** | `.zaq-btn-primary` | Animated 30deg neon gradient, white text, 2px `--zaq-border-color-accent` border | Gradient **continues**; animation **pauses**; text stays white; border shifts to `--zaq-text-color-body-accent` | One per LiveView content area (excludes modals/drawers) |
| **Secondary** | `.zaq-btn-secondary` | Transparent bg, neutral border, tertiary text | Base surface bg, secondary text, accent border | Standard supporting action |
| **Ghost** | `.zaq-btn-ghost` | Transparent bg, no border, accent text | Accent-tinted bg (`surface-accent`) | Minimal in-context actions |
| **Tertiary** | `.zaq-btn-tertiary` | Elevated surface bg, tertiary text | Accent surface bg, secondary text | Dense UI (ingestion lists). Modifiers: `.zaq-btn-tertiary--active`, `.zaq-btn-danger` |

All buttons share: `.zaq-btn` base, 8px radius, `.zaq-btn-text_label-default` typography, consistent focus affordances.

**Pill chip** — `.zaq-btn-pill` + `.zaq-btn-secondary` for outline chips only.

**Icon-only** — `.zaq-btn-icon` on `.zaq-btn`: 32×32px min, grid-centered, no label. Compose with any variant (e.g. `.zaq-btn.zaq-btn-icon.zaq-btn-ghost`). Always set `aria-label`.

Use `ZaqWeb.Components.DesignSystem.Button` — do not rebuild button markup from scratch.

### Form Controls

> Canonical: `assets/css/form.css` + `lib/zaq_web/components/design_system/` form modules.

All controls share: `surface-raised` background, `border-default` stroke, 16px radius. On focus: animated neon conic-gradient border. Error state: `border-danger` stroke.

**Composition pattern:**

1. **Layout wrapper** — `.zaq-field-row-block` (stacked) or `.zaq-field-row-inline` (side-by-side)
2. **Control shell** — `.zaq-control-text`, `.zaq-control-select`, or component module for richer controls
3. **Error row** — `.zaq-field-error` below the control when validation fails

| Component | Module |
|---|---|
| Input | `ZaqWeb.Components.DesignSystem.Input` |
| SecretInput | `ZaqWeb.Components.DesignSystem.SecretInput` |
| Checkbox | `ZaqWeb.Components.DesignSystem.Checkbox` |
| Toggle | `ZaqWeb.Components.DesignSystem.Toggle` |
| Dropzone | `ZaqWeb.Components.DesignSystem.Dropzone` |
| Select | `ZaqWeb.Select` |
| SearchableSelect | `ZaqWeb.Components.SearchableSelect` |

New form components may live under `design_system/` or `components/` — no DESIGN.md update required per component.

### Cards

`.zaq-card-default` — 16px padding, gap, and radius via shape tokens. `.zaq-card-hover` — raised surface + accent border on hover when direct child of `a`, `button`, or interactive role element.

### Data tables

> Canonical: `assets/css/table.css` + `storybook/core_components/table.story.exs`.

Use `.zaq-table` shell and related cell patterns — do not duplicate table styling in `styles.css` or templates.

### Design system component inventory

> Check `storybook/` before building anything new.

| Component | Module | Purpose |
|---|---|---|
| Button | `ZaqWeb.Components.DesignSystem.Button` | All button variants, pill, icon, danger |
| Link | `ZaqWeb.Components.DesignSystem.Link` | Anchor with DS styling |
| StatusBadge | `ZaqWeb.Components.DesignSystem.StatusBadge` | Inline status indicator |
| StatusPill | `ZaqWeb.Components.DesignSystem.StatusPill` | Pill-shaped status label |
| Breadcrumb | `ZaqWeb.Components.DesignSystem.Breadcrumb` | Page hierarchy |
| TabNav | `ZaqWeb.Components.DesignSystem.TabNav` | Tab section navigation |
| EmptyState | `ZaqWeb.Components.DesignSystem.EmptyState` | Zero-data placeholder + CTA |
| MetricCard | `ZaqWeb.Components.DesignSystem.MetricCard` | KPI display |
| DiagnosticCard | `ZaqWeb.Components.DesignSystem.DiagnosticCard` | System health summary |
| SimplePagination | `ZaqWeb.Components.DesignSystem.SimplePagination` | List page controls |
| AddonUpsellCard | `ZaqWeb.Components.DesignSystem.AddonUpsellCard` | Feature gating / upsell |

Feature-scoped modules (ingestion file browser, modals, etc.) live under `design_system/` with matching stories under `storybook/ingestion/` or `storybook/components/`.

### Modals

> Canonical: `assets/css/modal.css` + `ZaqWeb.Components.DesignSystem.*` modal modules + `storybook/components/modals/`.

- `.zaq-modal` — panel (`surface-raised`), 16px radius, 32px padding, `border-default`, tonal shadow
- `.zaq-bo-modal-backdrop` — scrim at 40% `text-default` with `backdrop-filter: blur(4px)`
- `.zaq-modal--flush` — removes padding for edge-to-edge content (file preview, toolbars)

Shell classes consume semantic tokens and adapt in dark mode automatically.

---

## Dark Mode

Dark mode activates via `data-zaq-theme="dark"` on any ancestor (typically `<html>`). Foundation palette vars flip in `foundations.css`; semantic tokens inherit the new values through `var()` chains — no component-level overrides needed for correctly-built UI.

**Explicit semantic overrides** (in `semantics.css` dark block):

- `--zaq-surface-color-base` and `--zaq-surface-color-raised` swap to preserve surface hierarchy
- `--zaq-border-color-default` and `--zaq-border-color-strong` swap for visible separation

**Also adapts via foundation cascade** (no separate semantic override, but values change):

- Ink scale — `text-default`, `text-secondary`, `text-tertiary` lighten against dark backgrounds
- `surface-elevated`, `surface-accent`, feedback surfaces and borders
- `text-accent`, `border-accent`, `icon-accent` — accent hues shift for dark palette legibility
- System feedback strong colors (`text-danger/success/warning`) — tuned for WCAG on dark surfaces

**Mode-agnostic:**

- Neon gradient stops and primary button animation
- Semantic *roles* (danger = destructive, success = positive) — hues adapt but meaning does not invert

**Note:** `btn.css` has one legacy override keyed on `[data-theme="dark"]` (secondary resting border). Prefer `data-zaq-theme="dark"`; both may be set on `<html>` in production.

---

## Do's and Don'ts

### Token usage

- Do use `--zaq-*` semantic tokens — never raw hex or legacy variable names in templates.
- Do use inline `style="color: var(--zaq-*)"` or `style="background-color: var(--zaq-*)"` for **color-only** swaps — never hardcoded hex inline.
- Don't use inline `style` for spacing, layout, `font-size`, or shape tokens — use `.zaq-layout-*`, role CSS classes, or new reusable classes in `styles.css`.
- Don't use text-only scale tokens (`--zaq-scale-10/12/14/20`) for padding, margin, gap, width, height, or border-radius.
- Don't use inline `font-size: var(--zaq-scale-*)` — use `.zaq-text-*` classes.
- Do apply WCAG AA contrast: use `text-danger/success/warning` for text and icons on feedback surfaces, never the full-strength system border colors for body text.

### Component reuse

- Do wrap every BO LiveView in `ZaqWeb.Components.BOLayout.bo_layout` — it is the only approved page shell.
- Do check `lib/zaq_web/components/` and Storybook before building any new UI element.
- Do use `ZaqWeb.Components.DesignSystem.*` modules for buttons, links, inputs, modals, cards, badges, and navigation.
- Don't use more than one `.zaq-btn-primary` per LiveView content area (modals and drawers are separate).
- Don't apply `.zaq-btn-text_label-default` outside `.zaq-btn`.
- Don't reference `--zaq-btn-*` tokens outside `btn.css`.
- Don't mix 8px and 16px radius on the same element.

### Layout & Tailwind

- **Forbidden:** Tailwind color and typography utilities (`text-sm`, `bg-white`, `text-gray-*`, `font-mono`).
- **Allowed only when DS has no matching layout utility:** Tailwind layout/spacing (`flex`, `grid`, `gap-4`, `p-8`) for one-off sizing with no `.zaq-layout-*` or role CSS class yet. Prefer `.zaq-layout-*` or migrate via `/design-migrate`.
- **Forbidden:** daisyUI component classes (`btn`, `card`, `modal`) — use `.zaq-btn`, `.zaq-modal`, `.zaq-card-*`.

### Legacy

- `app.css` is read reference only — never add patterns or use its utility classes.
- When you encounter legacy patterns in existing code, leave them unless explicitly migrating that component.
- During migration, do not mix old and new token patterns in the same file.
