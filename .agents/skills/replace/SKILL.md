---
name: replace
description: >
  Find inline UI that matches an existing reusable component under lib/zaq_web/components/,
  report replacement candidates for human approval, wire approved components into
  LiveViews (imports, component calls, remove dead markup), and verify with e2e or
  ExUnit. Use after extract and design-migrate when call sites still duplicate markup.
---

# Replace — wire reusable components into call sites

## When to use

- A reusable component already exists (from **extract**, prior PR, or Storybook) but **LiveViews still contain duplicate inline markup**.
- Typical position in workflow: **extract → design-migrate → replace** (human confirms each step).
- Optional input: a specific **component module**, a **scan scope** (LiveView path or directory), or both.

## Allowed writes

| Path | Rule |
|------|------|
| `lib/zaq_web/` | LiveViews, `*_components.ex`, layouts — markup and imports only; do not change business logic, assigns semantics, or event handler behavior unless the user explicitly asked. |
| `assets/css/styles.css` | Remove dead feature-scoped rules **only after** confirming they are unused post-replacement. |
| `test/` | ExUnit or e2e updates when selectors or structure change. |

**Do not create new DesignSystem modules here** — that is **extract**. If no suitable component exists, stop and run **extract** first.

## Discovery inputs

Before scanning, read **`DESIGN.md`** and gather the **full component catalog** under `lib/zaq_web/components/` — not only `design_system/`.

### 1. `lib/zaq_web/components/design_system/*.ex` (preferred for BO)

Primary DS modules — buttons, inputs, modals, badges, cards, ingestion chrome, etc. See `DESIGN.md` inventory.

### 2. Other shared modules (`lib/zaq_web/components/*.ex`)

Scan every top-level module. Common reuse targets:

| Module | Key functions |
|--------|---------------|
| `BOLayout` | `bo_layout`, `diagnostic_card`, `config_row`, `status_badge`, `feature_gate` |
| `BOModal` | `modal_shell`, `confirm_dialog`, `form_dialog` |
| `BOTelemetryComponents` | `metric_card`, charts, `status_grid`, etc. |
| `MasterDetailLayout` | `master_detail` |
| `SearchableSelect` | `searchable_select` |
| `ZaqWeb.Select` | `select` |
| `RoleSharePicker` | `role_share_picker` |
| `PasswordPolicyComponents` | `password_requirements` |
| `FilePreview` | `meta`, `panel` |
| `FilePreviewModal` | modal wrapper |
| `ServiceUnavailable` | `page` |
| `ConnectCredentialForm` | credential forms |
| `ChannelCapabilities` | channel UI |
| `IconRegistry` | `icon` (nav icons) |

Also grep `lib/zaq_web/chat/` and feature-specific `*_components.ex` next to LiveViews when the scan scope is feature-local.

### 3. Legacy — use only when no DS equivalent exists

| Module | Notes |
|--------|-------|
| `core_components.ex` | `<.input>`, `<.button>`, `<.table>`, `<.icon>` — **prefer `DesignSystem.*` in BO**; replace daisyUI `<.button>` with `DesignSystem.Button` when migrating |

### 4. Storybook

- `storybook/components/**/*.story.exs` — all categories, not only `design_system/`
- Match story `function` to module API before proposing replacement

**Catalog command (run before step 1):**

```bash
ls lib/zaq_web/components/*.ex lib/zaq_web/components/design_system/*.ex 2>/dev/null
```

For each candidate inline region, check **DesignSystem first**, then shared modules above, then legacy core components.

## Procedure

### 1. Identify replacement opportunities

Match **inline UI regions** in the scan scope to an existing component when:

- **Structure and role align** — same user-visible band (toolbar, banner, meta row, modal shell, etc.).
- **Assigns / events map cleanly** — component `attr`s cover what the inline markup needs; `phx-click` / `phx-target` can stay on the parent or pass through unchanged.
- **No meaningful behavior gap** — the standalone component is not missing slots, states, or hooks the inline version uses.

For each opportunity record:

- **Call site** — `file:line–line`
- **Target component** — full module + function (e.g. `ZaqWeb.Components.DesignSystem.Button.button/1`, `ZaqWeb.Components.BOModal.confirm_dialog/1`)
- **Confidence** — `high` (drop-in), `medium` (minor attr mapping), `low` (needs extract or component extension first — **do not replace**; flag for human)

Also note **other occurrences** repo-wide if the same inline pattern appears elsewhere (candidate for the same replacement in one PR or follow-ups).

### 2. E2E coverage cross-check (required — before the replacement report)

For each candidate, map to hosting LiveView(s) / routes and stable test hooks (`data-testid`, `role`, ids referenced in specs).

Using `docs/e2e-testing.md` and `test/e2e/specs/`:

- **Spec file:** e.g. `…/live/bo/agents_live.ex` → `test/e2e/specs/agents.spec.js`, or **`—`**.
- **Search specs** for selectors or flows tied to **this UI region**.
- **Tests raw UI** — **`yes`** / **`no`** / **`partial`** (e2e-only).
- **Coverage** — **`covered`**, **`partial`**, or **`none`**.

Flag **E2E notes** when replacement would move or rename nodes tests depend on — **preserve ids and `data-testid` on the component API**; add wrappers only if tests still resolve.

### 3. Human validation (required — do not skip)

**Stop** and output a **Replacement report**. **Do not start step 4** until the human approves rows (by #).

| # | Call site | Inline role | Target component | Confidence | Other occurrences | Tests raw UI | E2E spec(s) | E2E coverage | E2E notes |
|---|-----------|-------------|------------------|------------|-------------------|--------------|--------------|----------------|------------|
| 1 | … | … | `Module.function/1` | high / medium / low | … | yes / no / partial | … | covered / partial / none | … |

**Human gate:** Ask clearly: “Approve rows to replace (by #), request edits/merges/splits, or cancel.” **Wait for a reply.** Skip **low** confidence rows unless the human explicitly accepts the gap (extend component via **extract** PR first).

### 4. Replace at call sites

For each **approved** row:

- `import` or `alias` the target module in the hosting LiveView/component.
- Replace the inline `~H"""…"""` block with the component call.
- **Map assigns and slots** to the component’s public API; keep **event names** and **phx-target** behavior identical.
- **Preserve** e2e hooks (`id`, `data-testid`, `role`).
- Remove **dead** private helpers and markup **only** used by the replaced block.
- Remove **orphaned CSS** in `assets/css/styles.css` if nothing else references it.
- Run **`mix format`**.

**Do not** change unrelated regions in the same edit.

### 5. Verify

- Run **`mix q`** before opening the PR.

**E2E (when specs exist)**

- Derive slug from the consuming LiveView path (`…/live/bo/agents_live.ex` → `agents`) and run `test/e2e/specs/<slug>.spec.js` **if the file exists**.
- If **`ZaqWeb.Components.BOLayout`** or another **BO-wide layout** changed, also run `test/e2e/specs/agents.spec.js` as representative smoke.

**When no e2e spec exists**

- Extend **LiveView / component ExUnit** for critical paths, **or** document **manual smoke** steps in the PR.

**Storybook**

- No new story required if the component already has one; update the story **only** if the public API changed during wiring (rare — prefer fixing the component in a separate **extract** follow-up).

### 6. Workflow and PR hygiene

- Follow **`docs/WORKFLOW_AGENT.md`** and Beadwork (`bw prime`) for multi-step work per **AGENTS.md**.
- Prefer **one PR per coherent replacement** (one component adopted across related call sites, or one LiveView fully migrated).
- PR description: link the **target module**, list **call sites changed**, and note e2e runs.

## Coordination with other skills

| Skill | When |
|-------|------|
| **extract** | No suitable component exists, or the module is missing attrs/slots/states needed for a safe replacement. |
| **design-migrate** | Run **before replace** on extracted modules; can also run on call sites after replace for remaining token debt. |

Typical order: **extract** → **design-migrate** → **replace** (human confirmation at each gate).

## Out of scope

- Creating new `ZaqWeb.Components.DesignSystem.*` modules (**extract**).
- New business rules, schemas, or `lib/zaq/` contexts.
- Router, plugs, Oban workers, `mix.exs`, `config/` — unless explicitly requested.
- Changing component APIs for new features without a dedicated **extract** (or component) PR.
