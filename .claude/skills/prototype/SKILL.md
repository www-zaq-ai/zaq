---
name: prototype
description: >-
  Builds a design-system-aligned UI simulation from a UX plan using static fixtures.
  Output lives in lib/zaq_web/playground/ and assets/css/playground.css only — no
  Storybook, no design system edits, no production routes. Use after /ux-design
  before /design.
---

# Prototype — UX plan to isolated simulation

**Announce at start:** "Using /prototype — reading DESIGN.md, then building playground simulation"

## Role

You are a **prototype builder**, not a product engineer.

| You do | You do not |
|--------|------------|
| Simulate end-product screens with static data | Add production routes, LiveViews, or sidebar entries |
| **Import** existing components **read-only** when they fit exactly | **Edit** any file under `lib/zaq_web/components/` |
| Build **equivalent HTML** stubs when a component is missing or insufficient | Touch **Storybook** (`storybook/**`) or design system CSS |
| Style stubs via **`assets/css/playground.css`** (scoped, prototype-only) | Edit `app.css`, `styles.css`, `btn.css`, or other role CSS files |
| Read **`DESIGN.md`** + Storybook **read-only** for token/class reference | Promote playground code into production paths |
| Flag gaps (`# Component gap:` in `@moduledoc`) for **`/design`** | Create README, reports, or docs |

**Isolation rule:** Only create or edit files under:

- `lib/zaq_web/playground/**`
- `assets/css/playground.css`

Every other path is **read-only** — including all of `storybook/`, `lib/zaq_web/components/`, and `lib/zaq_web/live/`.

---

## Inputs

- Path to UX plan (e.g. `docs/ux/process-monitor.md`) — **primary input**
- Feature slug (kebab-case) when the UX plan path is omitted
- Optional: which screens or states to prioritize when the plan is large

If no UX plan exists, stop and ask the user to run **`/ux-design`** first.

---

## Output layout

Each feature gets one slug folder under playground:

```
lib/zaq_web/playground/
  registry.ex                    # slug → prototype module (append entry per feature)
  {feature-slug}/
    fixtures.ex                  # static demo data
    {feature}_prototype.ex       # LiveComponent — screens, scenarios, navigation
    components/                  # HTML stubs for gaps / [NEW] blocks

assets/css/
  playground.css                 # prototype-only styles (shared file, scoped sections)
```

**Module naming:**

| File | Module |
|------|--------|
| `registry.ex` | `ZaqWeb.Playground.Registry` |
| `fixtures.ex` | `ZaqWeb.Playground.{Feature}.Fixtures` |
| `{feature}_prototype.ex` | `ZaqWeb.Playground.{Feature}.Prototype` |
| `components/*.ex` | `ZaqWeb.Playground.{Feature}.Components.*` |

Use `{Feature}` = PascalCase of slug (`process-monitor` → `ProcessMonitor`).

**Preview:** prototypes mount via the shared **Playground host** at `/playground/:slug` (host LiveView + route are one-time infra — this skill registers the slug in `registry.ex` only; it does **not** edit `router.ex`).

---

## Procedure

### 1. Read DESIGN.md (mandatory — read-only reference)

**Read `DESIGN.md` in full** before writing HEEX. The simulation should **look like** production BO UI but must not modify the design system.

| Section | Use in prototype |
|---------|------------------|
| **Component inventory** | Decide import vs HTML stub (step 3) — reference only |
| **Token naming** | `--zaq-*` semantic vars in markup and `playground.css` |
| **Typography** | `.zaq-text-*` classes — never inline `font-size` |
| **Do's and Don'ts** | No hex, no `--zaq-btn-*` in templates |
| **Layout & Tailwind** | Layout Tailwind only when DS has no utility |

Read Storybook and `docs/bo-components.md` **read-only** to copy markup patterns — **never write** to `storybook/`.

### 2. Read the UX plan

Extract page inventory, screen specs, states, component mapping, and flows to simulate.

Resolve open questions with sensible static defaults; note assumptions in fixtures `@moduledoc` if non-obvious.

### 3. Map components (before HEEX)

| UX block | Strategy |
|----------|----------|
| Exact fit | **Import read-only** (e.g. `BOLayout.bo_layout`, `EmptyState`) |
| Partial fit | **HTML stub** + `# Component gap:` flag |
| `[NEW COMPONENT]` | **HTML stub** + `# Component gap:` flag |
| No DS equivalent | **HTML stub** with `.zaq-*` classes |

```
Does an existing component satisfy the UX spec without changes?
  YES → import read-only
  NO  → HTML stub in playground/components/ + flag for /design
  NEVER → edit lib/zaq_web/components/**
```

### 4. Define fixtures

Static scenarios in `fixtures.ex` — no DB, no contexts.

### 5. Build the interactive shell

Single **LiveComponent** (`Prototype`) per feature:

- `assign(:screen, …)` and `assign(:scenario, …)` for navigation and states
- `phx-click` switches screen/scenario — no `push_navigate` to production routes
- **Exact-fit blocks** → read-only imports
- **Gaps** → playground HTML stub components
- Optional in-UI scenario switcher (tabs/select) — not Storybook controls

Wrap full-page simulations in `BOLayout.bo_layout` (read-only import) with fake assigns.

### 6. Playground CSS (`assets/css/playground.css`)

Use when stub layout cannot be achieved with existing DS classes alone.

**Rules:**

| Rule | Detail |
|------|--------|
| **Single file** | All prototype CSS goes in `assets/css/playground.css` — append a commented section per feature |
| **Scoped** | Every selector prefixed `.zaq-playground--{slug}` (e.g. `.zaq-playground--process-monitor .health-summary`) |
| **Not in app bundle** | **Do not** `@import` into `app.css` — loaded only by the Playground host layout |
| **Prefer tokens** | Use `var(--zaq-*)` — raw hex only when no semantic token exists |
| **Disposable** | Rules simulate the end product; `/design` rebuilds properly in role CSS |

Example section:

```css
/* --- process-monitor (prototype — not production) --- */
.zaq-playground--process-monitor .health-summary {
  display: flex;
  gap: var(--zaq-scale-8);
}
```

### 7. Register in `registry.ex`

Append an entry so the Playground host can mount the prototype:

```elixir
%{
  slug: "process-monitor",
  module: ZaqWeb.Playground.ProcessMonitor.Prototype,
  title: "Process Monitor",
  css_scope: "zaq-playground--process-monitor"
}
```

Do **not** edit `router.ex`.

### 8. Design system audit (mandatory)

Grep new playground files for violations:

| Pattern | Verdict |
|---------|---------|
| Diffs under `storybook/**` | **Fail** |
| Diffs under `lib/zaq_web/components/**` | **Fail** |
| Diffs under `assets/css/` except `playground.css` | **Fail** |
| `#[0-9a-fA-F]{3,8}` outside `var(--zaq-*)` | **Fail** |
| `app.css` classes, daisyUI | **Fail** |
| Forbidden Tailwind color/typography utilities | **Fail** |
| Unscoped rules in `playground.css` (missing `.zaq-playground--{slug}`) | **Fail** |

### 9. Verify

1. `mix format` on touched files
2. Confirm diffs **only** in `lib/zaq_web/playground/**` and `assets/css/playground.css`
3. Run **`/run`** → open `/playground/{slug}` (when host exists) and walk the happy path

---

## Allowed writes

| Path | Purpose |
|------|---------|
| `lib/zaq_web/playground/**` | Registry, fixtures, LiveComponent, HTML stubs |
| `assets/css/playground.css` | Prototype-only scoped CSS |

## Forbidden writes

| Path | Reason |
|------|--------|
| `storybook/**` | No impact on design system documentation |
| `lib/zaq_web/components/**` | Existing components read-only |
| `lib/zaq_web/live/**` | No production LiveViews |
| `lib/zaq_web/router.ex` | No route changes from this skill |
| `assets/css/**` except `playground.css` | No design system CSS changes |
| `lib/zaq/**` | No backend |
| `config/**`, `mix.exs`, `priv/**` | No infrastructure |
| `docs/**` | No documentation output |

---

## Quality checklist

- [ ] **`DESIGN.md` read** (reference only); import vs HTML-stub decided per block
- [ ] **Zero diffs** under `storybook/` and `lib/zaq_web/components/`
- [ ] All screens and states from UX plan reachable in LiveComponent
- [ ] Static data only — no `Repo.`, `NodeRouter`, contexts
- [ ] `# Component gap:` flags on HTML stubs where relevant
- [ ] `playground.css` sections scoped with `.zaq-playground--{slug}`
- [ ] Slug registered in `registry.ex`
- [ ] Design system audit passes

---

## Handoff

Human reviews simulation at `/playground/{slug}` → approves or revises UX plan → run **`/design`** to implement flagged gaps in `DesignSystem.*` and wire production UI.

**Do not** wire playground modules into the BO sidebar or production router.
