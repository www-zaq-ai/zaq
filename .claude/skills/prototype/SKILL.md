---
name: prototype
description: >-
  Stages UX-plan features on real BO routes using static fixtures. May update DSM
  (DesignSystem.*), existing components, CSS, router, and sidebar. Never touches
  backend (lib/zaq/**, NodeRouter, migrations). Use after /ux-design; hand off to
  /design for production-ready DS patterns and data wiring.
---

# Prototype — UX plan to staged BO feature

**Announce at start:** "Using /prototype — reading DESIGN.md, then staging feature on BO routes with fixtures"

## Role

You are a **front-end prototype builder**, not a backend engineer.

| You do | You do not |
|--------|------------|
| Wire **real BO LiveViews** under `lib/zaq_web/live/bo/` | Call `NodeRouter`, `Repo`, or any `lib/zaq/` context |
| Load data from **`Fixtures` modules only** | Add migrations, schemas, Oban workers, config changes |
| **Create or extend** `DesignSystem.*` when UX requires it | Change backend API contracts or event payloads |
| **Extend existing components** when a small variant unlocks the flow | Ship production data wiring (post-review / **`/design`**) |
| Read **`DESIGN.md`** + Storybook **read-only** as the DS contract | Create or edit Storybook stories (that is **`/design`** / **`/extract`**) |
| Register **BO routes and sidebar** entries for discoverability | Treat prototype DSM edits as final production patterns without review |
| Flag DSM gaps for **`/design`** when a component needs hardening | Write docs/reports unless asked |

**Leverage `/design`:** read `DESIGN.md` and existing Storybook the same way `/design` does. Prototype may extend DSM pragmatically for staging; **`/design`** owns production-ready patterns, Storybook, and real data wiring.

---

## Inputs

- Path to UX plan (e.g. `docs/ux/process-monitor.md`) — **primary input**
- Feature slug (kebab-case) when the UX plan path is omitted
- Optional: which screens or states to prioritize when the plan is large

If no UX plan exists, stop and ask the user to run **`/ux-design`** first.

---

## Output layout

Each feature gets real BO wiring with fixtures:

```
lib/zaq_web/
  fixtures/{feature_slug}.ex          # static demo data + scenarios
  live/bo/{feature_slug}_live.ex      # LiveView — mount/handle_event use fixtures only
  live/bo/{feature_slug}_live.html.heex
  components/design_system/...        # new or extended DSM modules (when needed)
  components/...                      # extended shared components (when needed)
  router.ex                           # live route under :bo session
  components/bo_layout.ex             # sidebar nav entry (when feature needs discoverability)

assets/css/                           # role CSS / styles.css per DESIGN.md (when needed)
```

**Not in prototype scope:** `storybook/**` — Storybook stories are owned by **`/design`** (typically via **`/extract`**).

**Module naming:**

| File | Module |
|------|--------|
| `fixtures/{slug}.ex` | `ZaqWeb.Fixtures.{Feature}` |
| `live/bo/{slug}_live.ex` | `ZaqWeb.Live.BO.{Feature}Live` |

Use `{Feature}` = PascalCase of slug (`process-monitor` → `ProcessMonitor`, `ProcessMonitorLive`).

**Preview:** feature mounts at **`/bo/{slug}`** inside the real BO shell (`BOLayout.bo_layout`, sidebar, flash).

---

## Fake data contract (mandatory)

Every prototype feature **must** stage data without touching backend structure:

- LiveView **`mount/3`** and all event handlers read from **`ZaqWeb.Fixtures.{Feature}`** — no DB, no `NodeRouter.dispatch/1`, no context calls
- Fixtures hold all scenarios from the UX plan (happy path, empty, error, permission variants)
- **`@moduledoc`** on LiveView and Fixtures must note **`@prototype true`** so reviewers know data is staged
- **`handle_event` that would persist** → update in-memory fixture state via `assign/2` only — never dispatch backend events
- If UX requires a component API that does not exist → extend DSM or add a new `DesignSystem.*` module — do not stub in a throwaway folder

---

## Procedure

### 1. Read DESIGN.md (mandatory)

**Read `DESIGN.md` in full** before writing HEEX. Prototype output should look like production BO UI.

| Section | Use in prototype |
|---------|------------------|
| **Component inventory** | Decide import vs extend vs new DSM module (step 3) |
| **Token naming** | `--zaq-*` semantic vars in markup and CSS |
| **Typography** | `.zaq-text-*` classes — never inline `font-size` |
| **Do's and Don'ts** | No hex, no `--zaq-btn-*` in templates |
| **Layout & Tailwind** | Layout Tailwind only when DS has no utility |

Read Storybook and `docs/bo-components.md` **read-only** for markup patterns — **never write** to `storybook/`.

### 2. Read the UX plan

Extract page inventory, screen specs, states, component mapping, and flows to simulate.

Resolve open questions with sensible static defaults; note assumptions in fixtures `@moduledoc` if non-obvious.

### 3. Map components (before HEEX)

| UX block | Strategy |
|----------|----------|
| Exact fit | **Import** existing component (e.g. `BOLayout.bo_layout`, `EmptyState`) |
| Partial fit | **Extend** existing `DesignSystem.*` or shared component |
| `[NEW COMPONENT]` | **New** `DesignSystem.*` module — flag for **`/design`** hardening |
| No DS equivalent | **New** `DesignSystem.*` with `.zaq-*` classes — flag for **`/design`** |

```
Does an existing component satisfy the UX spec without changes?
  YES → import
  NEEDS VARIANT → extend existing component or DesignSystem.*
  NEW → add DesignSystem.* module + flag for /design (Storybook, hardening)
  NEVER → NodeRouter, Repo, or lib/zaq/ context calls
```

### 4. Define fixtures

Static scenarios in `lib/zaq_web/fixtures/{slug}.ex` — cover all UX states. No DB, no contexts.

### 5. Build the LiveView

One **LiveView** per feature (`{Feature}Live`):

- `assign(:screen, …)` and `assign(:scenario, …)` for navigation and states when the UX plan has multiple views
- `phx-click` switches screen/scenario — use `push_patch` within the feature route when needed
- **Exact-fit blocks** → import existing components
- **Gaps** → new or extended `DesignSystem.*` modules
- Optional in-UI scenario switcher (tabs/select) for reviewing states

Wrap every page in `BOLayout.bo_layout` with fake assigns (`current_user`, `current_path`, `features_version`, etc.) sourced from fixtures.

### 6. CSS (when needed)

Use role CSS / `styles.css` per **`DESIGN.md`** rules when DS classes alone are insufficient.

| Rule | Detail |
|------|--------|
| **Prefer DS classes** | Use existing `.zaq-*` before adding CSS |
| **Token-first** | Use `var(--zaq-*)` — raw hex only when no semantic token exists |
| **Not app.css** | Never edit `assets/css/app.css` |
| **Disposable staging** | Prototype CSS is staging; **`/design`** hardens patterns in role CSS |

### 7. Register route and sidebar

Add route in `lib/zaq_web/router.ex` under the `:bo` live session:

```elixir
live "/process-monitor", Live.BO.ProcessMonitorLive
```

Add sidebar entry in `lib/zaq_web/components/bo_layout.ex` when the feature needs discoverability — mark with a `# @prototype` comment.

Set `current_path` assign to match the route (e.g. `"/bo/process-monitor"`) for active nav highlighting.

### 8. Design system audit (mandatory)

Grep touched files for violations:

| Pattern | Verdict |
|---------|---------|
| Diffs under `storybook/**` | **Fail** |
| `NodeRouter`, `Zaq.Repo`, `Ecto.`, or `alias Zaq.` (non-`ZaqWeb`) in LiveView/fixtures | **Fail** |
| Diffs under `lib/zaq/**` | **Fail** |
| Diffs under `config/**`, `mix.exs`, `priv/repo/migrations/**` | **Fail** |
| `#[0-9a-fA-F]{3,8}` outside `var(--zaq-*)` | **Fail** |
| `app.css` classes, daisyUI | **Fail** |
| Forbidden Tailwind color/typography utilities | **Fail** |

### 9. Verify

1. `mix format` on touched files
2. Confirm no backend or Storybook diffs
3. Run **`/run`** → open `/bo/{slug}` and walk the happy path

---

## Allowed writes

| Path | Purpose |
|------|---------|
| `lib/zaq_web/**` | LiveViews, components, router, fixtures, sidebar |
| `assets/css/**` (not `app.css`) | Staging CSS per DESIGN.md |

## Forbidden writes

| Path | Reason |
|------|--------|
| `storybook/**` | Storybook owned by **`/design`** / **`/extract`** |
| `lib/zaq/**` | No backend |
| `priv/repo/migrations/**`, `priv/repo/seeds*` | No DB structure changes |
| `config/**`, `mix.exs` | No infrastructure |
| `docs/**` | No documentation output unless asked |
| `NodeRouter` / context wiring in LiveViews | Fake data only |

---

## Quality checklist

- [ ] **`DESIGN.md` read**; import vs extend vs new DSM decided per block
- [ ] **Zero diffs** under `storybook/` and `lib/zaq/`
- [ ] All screens and states from UX plan reachable at `/bo/{slug}`
- [ ] Static data only — fixtures module, no `Repo.`, `NodeRouter`, contexts
- [ ] LiveView and Fixtures `@moduledoc` note `@prototype true`
- [ ] Route registered in `router.ex`; sidebar entry when needed
- [ ] DSM gaps flagged for **`/design`** follow-up
- [ ] Design system audit passes

---

## Handoff

1. Human reviews staged UI at **`/bo/{slug}`** in the real BO shell
2. Gaps needing **production data wiring** or **DS hardening** → **`/design`** (extract / migrate / replace)
3. **`/design` is not blocked on prototype** — it runs independently for production-ready DSM work
4. Prototype output is **staging** until backend integration is explicitly scoped later (outside this skill)

**Do not** wire real backend data in this skill — that is post-review work via **`/design`** or a separate backend task.
