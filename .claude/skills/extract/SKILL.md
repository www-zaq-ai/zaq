---
name: extract
description: >
  Find cohesive UI slices, cross-check against existing reusable components, report
  candidates for human approval, copy approved slices into new (or extended)
  ZaqWeb.Components.DesignSystem modules (original call-site code stays intact),
  and add or update Storybook. Does not wire LiveViews and never invokes replace —
  flag replace candidates in the report for a human follow-up after design-migrate. Use before
  design-migrate when markup lives under lib/zaq_web/live/.
---

# Extract — UI slices into `ZaqWeb.Components.DesignSystem`

## When to use

- A LiveView or `*_components.ex` next to it contains **grouped UI** (toolbar, meta row, chips, banner) you want to **capture as a reusable component** before migration or adoption elsewhere.
- **Identify and extract only** — the source file is **read-only** for markup removal; wiring inline markup to an existing component is **replace** (human or another process — **never invoked by this skill**).
- **Presentation only** — not new `lib/zaq/` domain logic, routers, plugs, or config unless explicitly scoped.

## Allowed writes

| Path | Rule |
|------|------|
| `lib/zaq_web/components/design_system/` | New extracted modules **or** extend an existing module when the report recommends **extend** |
| `assets/css/styles.css` | Layout / color utilities needed by the new or extended component |
| `storybook/components/**` | **Update** an existing story **in place** when one documents the same UI role; add a new story only when none exists repo-wide — **never duplicate** |
| `test/zaq_web/components/design_system/` | ExUnit for the new or extended component (optional but recommended) |

**Do not edit** the LiveView or `*_components.ex` where the slice was found — no imports, no deletions, no replacements.

**Code vs Storybook location:** extracted **modules** always live under `design_system/`. Storybook stories live under the **category folder where humans already document that control** (e.g. `forms/` for input/button/checkbox) — **not** automatically under `design_system/` just because the module namespace changed.

## Host location (required)

- **Directory:** `lib/zaq_web/components/design_system/`
- **Module:** `ZaqWeb.Components.DesignSystem.<Name>`
- **File:** `lib/zaq_web/components/design_system/<snake_case>.ex`

**LiveComponent path (pick one convention per project and stay consistent):**

- **Flat:** `…/design_system/<name>_live.ex` → `ZaqWeb.Components.DesignSystem.<Name>Live`
- **Nested:** `…/design_system/live/<name>.ex` → `ZaqWeb.Components.DesignSystem.Live.<Name>`

Document the chosen pattern in the PR.

## Component type: default and escape hatch

**Default: Phoenix function component** (`use Phoenix.Component`, `attr` / `slot`). Events stay on the parent LiveView via `phx-click` / `phx-target` as in the source slice unless you intentionally change behavior in the extracted API.

**Use a LiveComponent only when several of these apply:**

- The slice has **its own** `handle_event` / update cycle you do not want on the page LiveView.
- It holds **meaningful private assigns** (draft values, internal steps, local selection) that are not the page’s responsibility.
- Extracting a process **clearly simplifies** the parent — not “because we can.”

If unsure, **start with a function component**; promote to LiveComponent only after the checklist above passes.

## Procedure

### 0. Read the contract

Read **`DESIGN.md`** before step 1. Consult Storybook for existing stories matching the slice role.

### 1. Identify similar elements

- Same **visual band** (padding, gap, label style) or repeated **controls** (buttons, toggles, icons).
- Same **interaction family** (navigation, filters, bulk actions).
- Prefer **one coherent slice per PR**; split by user-visible region if the slice is huge.
- Record **source location(s)** (`file:line–line`) for each candidate.

### 1b. Catalog cross-check (required — before the extraction report)

For **each candidate** from step 1, search for an **existing reusable** before suggesting a new module:

| Source | What to match |
|--------|----------------|
| `lib/zaq_web/components/design_system/*.ex` | Module name, public function(s), `attr` / slots |
| `storybook/components/**/*.story.exs` | Story ↔ component mapping — grep `CoreComponents.<fn>`, story module name, and story title; check **all** folders (`forms/`, `feedback/`, `design_system/`, etc.) |
| `lib/zaq_web/components/*.ex` (outside `design_system/`) | Shared BO components (e.g. `CoreComponents`, `SearchableSelect`, `BOModal`) — note module path in report |
| `assets/css/form.css`, `btn.css`, `modal.css`, `table.css`, `layout.css` | Primitive patterns — prefer existing classes over new CSS |

**When source is `core_components.ex` or another shared `lib/zaq_web/components/*.ex` module (required):**

- Grep `storybook/` for `CoreComponents.<function_name>` (and related story files, e.g. `checkbox.story.exs` + `textarea.story.exs` both wrapping `input/1`).
- If a story already documents the slice → report **Story action: update `<path>`** (retain folder). Do **not** plan a second story under `design_system/`.
- Related stories for the same function (e.g. checkbox/textarea variants of `input/1`) → note in report; step 6 may update **`function`** on each or consolidate per human preference.

Assign a **Recommendation** per row:

| Recommendation | Meaning | Step 4? |
|----------------|---------|---------|
| **`extract`** | No adequate reusable exists — create a **new** `DesignSystem.*` module | Yes, if human approves |
| **`extend`** | Reusable exists but missing attrs, slots, or states — **extend the existing module** (same file), do not fork | Yes, if human approves |
| **`replace`** | Existing component already covers this slice — inline markup should use it; **do not extract** | **No** — note in report only |
| **`skip`** | Out of scope, one-off, or no value in a shared component | **No** |

**Never invoke `/replace` or perform replace work in this skill.** Rows with **`replace`** or **`skip`** are informational: tell the human (or their process) that **replace** may apply — you do not run it, wire call sites, or remove inline markup.

### 2. E2E coverage cross-check (required — before the extraction report)

After steps 1–1b, map each **candidate slice** to its **hosting LiveView(s)** / routes and any **stable hooks** the UI already exposes for tests (`data-testid`, `role`, visible labels referenced in specs).

For each candidate, determine Playwright coverage using `docs/e2e-testing.md` and `test/e2e/specs/`:

- **Spec file:** Derive the slug from the consuming LiveView path (e.g. `…/live/bo/agents_live.ex` → `test/e2e/specs/agents.spec.js`). Note **`—` (none)** when that file does not exist.
- **Search specs:** Grep the relevant `*.spec.js` (and `test/e2e/support/bo.js` when shared helpers cover the flow) for route navigation, selectors, or test titles that exercise **the same page region or flow** as the slice.
- **Coverage label** — **`covered`**, **`partial`**, or **`none`**.
- **Tests raw UI** — **`yes`** / **`no`** / **`partial`**: does any **automated e2e** under `test/e2e/` target **this candidate slice’s** DOM or behavior?

Record results for the step 3 table. For **`replace`** rows, note in **E2E notes** that ids/markup must be preserved when a human later runs **replace**.

### 3. Human validation (required — do not skip)

After steps 1–2, **stop** and output an **Extraction report** to the human. **Do not start step 4** until the human explicitly approves which rows to proceed with (and any renames or merges).

**Only rows with Recommendation `extract` or `extend` are eligible for step 4.** Rows marked **`replace`** or **`skip`** require no extract work — list them so the human can run **replace** or ignore separately.

| # | Proposed slice name | Source location(s) | Occurrences | Function | Existing match | Recommendation | Suggested module / action | Story action | Tests raw UI | E2E spec(s) | E2E coverage | E2E notes |
|---|---------------------|--------------------|-------------|----------|----------------|----------------|---------------------------|--------------|--------------|--------------|----------------|------------|
| 1 | … | … | … | … | `—` or module/story path | extract / extend / replace / skip | … | update / create / none + path | yes / no / partial | … | covered / partial / none | … |

**Column definitions**

- **Proposed slice name** — Short human label (e.g. “Volume + volume chips row”).
- **Source location(s)** — Primary `file:line–line` (and others if repeated).
- **Occurrences** — Count within the **agreed scan scope**; note “N× in `<path>`, M× repo-wide” when relevant.
- **Function** — What it does for the user, not implementation detail.
- **Existing match** — Best matching module/class/story path, or **`—`**. Include non–`design_system` modules when relevant (e.g. `ZaqWeb.Components.SearchableSelect`).
- **Recommendation** — `extract`, `extend`, `replace`, or `skip` (from step 1b).
- **Suggested module / action** — For **`extract`**: new `DesignSystem.<Name>`. For **`extend`**: which existing module to extend and what gap (attrs/slots). For **`replace`**: target component + “human/process: run **replace**”. For **`skip`**: brief reason.
- **Story action** — From step 1b story search: **`update <path>`** (change `function` to `DesignSystem.*`, add variations — keep folder), **`create <path>`** (no existing story; pick category folder), or **`none`**. Never two stories for the same component.
- **Tests raw UI** — E2e-only; ExUnit mention goes in **E2E notes**.
- **E2E spec(s)** — Path(s) under `test/e2e/specs/`, or **`—`**.
- **E2E coverage** — `covered`, `partial`, or `none`.
- **E2E notes** — e.g. “preserve `data-testid` if replace follows”, “no spec for this LiveView”.

**Human gate:** Ask clearly: “Approve rows to extract or extend (by #), request edits/merges/splits, or cancel. Rows marked **replace** / **skip** are for your follow-up — this skill will not run replace.” **Wait for a reply.** Only then continue with step 4 for **approved** rows whose Recommendation is **`extract`** or **`extend`** only.

### 4. Extract (copy — do not modify source call sites)

**New module (`extract`):**

- Add `lib/zaq_web/components/design_system/<snake>.ex` with module `ZaqWeb.Components.DesignSystem.<Name>`.
- **Copy** `~H"""…"""` and helpers **used only** by that markup into the new module.

**Extend existing (`extend`):**

- Edit the **existing** module file — add `attr`s, slots, or variations needed by the slice.
- **Do not** create a second module or story for the same UI role.

**Both:**

- Define or update a clear **public API** (`attr`, slots) matching what call sites will need if **replace** runs later.
- Preserve **ids**, **event names**, and **assigns contract** from the source slice.
- New layout / color utilities → **`assets/css/styles.css`** only; use **semantic** tokens (align with **design-migrate** — no foundation vars in templates).
- **Leave the original LiveView / components file unchanged.**

### 5. Naming (case-by-case checklist)

- [ ] Name reflects **domain + role** (e.g. `FileBrowserChrome`), not a generic `Widget`.
- [ ] No module collision (`grep` / `mix compile`).
- [ ] File path matches module name.
- [ ] **`extend`** rows reuse the existing module name — no duplicate “Select2” / “SelectV2” unless human explicitly requested.

### 6. Storybook (required — no duplicate stories)

**Search scope:** entire `storybook/components/**/*.story.exs` — not only `design_system/`.

**Story folder rule:** module code lives in `design_system/`; the story file lives where the control is **already documented for humans** (usually `forms/` for form primitives). Do **not** mirror module namespace into `design_system/` unless no category folder fits and the slice is domain-specific chrome (e.g. ingestion modals).

| Situation | Action |
|-----------|--------|
| **Story exists** for the same UI role (any folder) | **Update in place** — point `function` at `DesignSystem.*`, add variations; **do not** create a second file |
| **Related stories** wrap the same source function (e.g. `checkbox.story.exs` + `textarea.story.exs` → `input/1`) | Update each related story’s `function`, or note consolidation for human approval |
| **No story** anywhere | **Create** in the best category folder (`forms/`, `feedback/`, `design_system/`, …); register in that folder’s `.index.exs` if needed |
| **`extend`** changed public API | Update the existing story to cover new attrs/slots/states |

**Anti-pattern:** extracting `CoreComponents.input/1` while leaving `forms/input.story.exs` on `CoreComponents` and adding `design_system/input.story.exs` — always **update** the existing Forms story instead.

- Use `PhoenixStorybook.Story` (`:component` or `:live_component` matching the module).
- Set `function` to **`&ZaqWeb.Components.DesignSystem.<Module>.<fun>/1`** (or LiveComponent API per Storybook docs).
- Provide **2–4 variations** with realistic assigns/slots (default, empty, disabled, error, etc.).
- Update **`test/e2e/support/story-urls.json`** when adding a new story path.

### 7. Verify

- Run **`mix format`** on touched files.
- Run **`mix q`** before opening the PR.
- Add or update **`render_component`** ExUnit for the module (assigns, slots, critical markup).
- **Story dedup check:** for each extracted function, grep `storybook/` — at most **one** story file should reference that UI role; no remaining `CoreComponents.<fn>` in story `function` for the extracted slice (unless explicitly kept in a deprecated folder).
- Confirm the story renders at `http://localhost:4000/storybook` (manual smoke or document in PR).

**Do not run consuming LiveView e2e specs in this skill** — call sites are unchanged. Full-page e2e belongs to **replace** after a human wires components in.

### 8. Workflow and PR hygiene

- Multi-step or cross-team work: follow **`docs/WORKFLOW_AGENT.md`** and Beadwork (`bw prime`) per **AGENTS.md**.
- Prefer **one PR per coherent extraction** unless you explicitly split for review.
- PR description: list **source location(s)**; for **`replace`** rows from the report, note “follow-up: human/process runs **replace**” — **do not** perform replace in this PR.

## Coordination with other skills

| Skill | Relationship to extract |
|-------|-------------------------|
| **replace** | **Separate process (step 3).** Extract may **flag** rows as **`replace`** in the report. Extract **never** calls replace or wires call sites. |
| **design-migrate** | Run **after extract** on the new/extended `DesignSystem` module + `styles.css` before replace. |

Typical human-driven order: **extract** → **design-migrate** → **replace** (human confirmation at each skill gate).

## Out of scope

- Running or invoking **replace** (no call-site wiring, no inline markup removal).
- Importing or calling components from LiveViews.
- Creating a **duplicate** module or Storybook story when a reusable already exists (use **`extend`** or report **`replace`** instead) — includes a second story in a different folder (`forms/input` + `design_system/input`).
- New business rules, schemas, or `lib/zaq/` contexts.
- Router, plugs, Oban workers, `mix.exs`, `config/` — unless explicitly requested.
