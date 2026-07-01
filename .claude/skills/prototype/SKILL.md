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

### 2. Read the UX plan (primary implementation spec)

Extract page inventory, screen specs, states, flows, and **§ Component mapping** (including **Form field mapping** when present).

**The UX plan is the feature-specific build list.** `/ux-design` maps each screen block to DSM modules; **`/prototype` implements that mapping verbatim.** Do not substitute raw HTML when the UX plan names a component.

Resolve open questions with sensible static defaults; note assumptions in fixtures `@moduledoc` if non-obvious.

### 3. Resolve components (before HEEX)

**Do not maintain a component list in this skill** — the inventory evolves in **`DESIGN.md`**. At build time:

1. Read **UX plan §5** (and §5b form fields) — one row = one implementation obligation.
2. Resolve module names from **`DESIGN.md`** (inventory + Form Controls) and **`docs/bo-components.md`**.
3. Spot-check **Storybook** read-only when the UX row is ambiguous.

| UX plan row | Strategy |
|-------------|----------|
| Named `DesignSystem.*` / `ZaqWeb.*` module, no gap | **Import** that module — no raw markup equivalent |
| Partial fit / variant noted | **Extend** existing `DesignSystem.*` or shared component |
| **`[NEW COMPONENT]`** or **`[GAP]`** | **New or extended** `DesignSystem.*` stub — flag for **`/design`** |
| Form field maps to a control type | Use the module named in UX plan; if **`[GAP]`**, use documented DSM field shell (`.zaq-field-row-block`, `.zaq-bo-checkbox`) — never invent classes |

**Form composition rule (mandatory):**

- **Never** use raw `<input>`, `<select>`, or `<textarea>` in LiveView templates under `live/bo/`.
- **Always** use modules resolved from **`DESIGN.md` § Form Controls** (e.g. `DesignSystem.Input`, `ZaqWeb.Select`, `SearchableSelect`, `DesignSystem.Checkbox`) unless UX plan marks **`[GAP]`** with an approved interim pattern.
- **Never** invent form classes (`zaq-input`, legacy `app.css` utilities, daisyUI). Control shells live in `assets/css/form.css` (`.zaq-control-text`, combobox trigger, etc.) and are applied via DSM modules.
- Before writing a form screen, grep `lib/zaq_web/live/bo/` for an existing form using DS imports — copy the **import / except pattern**, not ad-hoc markup.

```
UX plan row with no gap?
  YES → import named module from DESIGN.md
  [NEW COMPONENT] / [GAP] → extend DSM or approved gap pattern + flag for /design
  NEVER → raw form tags, invented classes, NodeRouter, Repo
```

List any **`[GAP]`** stubs and **`[NEW COMPONENT]`** modules in the LiveView `@moduledoc` for **`/design`** follow-up.

### 4. Define fixtures

Static scenarios in `lib/zaq_web/fixtures/{slug}.ex` — cover all UX states. No DB, no contexts.

**Fixture contract:**

- URL / query params are **strings** — normalize in fixtures (`to_scenario/1` or match both `"empty"` and `:empty`); never rely on atom-only function heads for param-driven data.
- **Scenario switcher** (when used):
  - Each scenario must change something **visible** on the intended screen (document which screen in fixtures `@moduledoc`).
  - Update URL via `push_patch` / `push_navigate` so `handle_params` reloads data.
  - Use `phx-value-*` attrs that the target component forwards (`DesignSystem.Button` only passes attrs in its `rest` include list — prefer `phx-value-id` or a native `<button class="zaq-btn …">` for prototype-only controls).
  - Auto-navigate to the screen where a scenario matters when the user is elsewhere (e.g. dashboard scenario → show view).

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
| Raw `<input`, `<select`, `<textarea` in `live/bo/*` (outside `DesignSystem.*`) | **Fail** |
| Invented form classes (`zaq-input`, etc.) | **Fail** |
| Form screen (`phx-submit` / `<.form`) with **no** `DesignSystem.Input`, `Select`, `SearchableSelect`, or `Checkbox` import | **Fail** |
| UX plan §5 row implemented with a different pattern than mapped (unless documented `[GAP]` in `@moduledoc`) | **Fail** |

### 9. Verify

1. `mix format` on touched files
2. Confirm no backend or Storybook diffs
3. Run **`/run`** → open `/bo/{slug}` and verify:
   - Happy path
   - **Every fixture scenario** (each changes visible UI on the intended screen)
   - **Every form screen** from the UX plan (create / edit / settings)
4. Confirm form controls match DSM modules named in UX plan §5 / §5b

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

- [ ] **UX plan §5 (+ §5b form fields) read** — every row implemented or documented `[GAP]` in `@moduledoc`
- [ ] **`DESIGN.md` read at build time** — modules resolved from live inventory, not skill memory
- [ ] **No raw form tags** in LiveView templates; form screens use DSM modules from UX mapping
- [ ] **Zero diffs** under `storybook/` and `lib/zaq/`
- [ ] All screens and states from UX plan reachable at `/bo/{slug}`
- [ ] Static data only — fixtures module, no `Repo.`, `NodeRouter`, contexts
- [ ] Fixture params normalized (string scenarios); scenario switcher tested per scenario
- [ ] LiveView and Fixtures `@moduledoc` note `@prototype true` + list `[NEW]` / `[GAP]` for `/design`
- [ ] Route registered in `router.ex`; sidebar entry when needed
- [ ] Design system audit passes

---

## Handoff

1. Human reviews staged UI at **`/bo/{slug}`** in the real BO shell
2. Gaps needing **production data wiring** or **DS hardening** → **`/design`** (extract / migrate / replace)
3. **`/design` is not blocked on prototype** — it runs independently for production-ready DSM work
4. Prototype output is **staging** until backend integration is explicitly scoped later (outside this skill)

**Do not** wire real backend data in this skill — that is post-review work via **`/design`** or a separate backend task.
