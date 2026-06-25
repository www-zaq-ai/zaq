---
name: design-migrate
description: Migrate legacy ZAQ web UI (components, LiveViews, layouts) styling to the --zaq-* token system. Reads DESIGN.md and CSS catalog (foundations, semantics, text-styles, btn, form, modal, table, layout, styles) before proposing changes. Accepts a Figma frame URL (design-led), a file path (audit), or --audit-all (full sweep). Typical position in workflow: after extract, before replace.
trigger: when the user types /design-migrate
---

# Design Migrate Skill

You are migrating ZAQ's styling incrementally to the `--zaq-*` token system.

**Announce at start:** "Using /design-migrate — [detecting mode from input]"

---

## File Write Restrictions (enforced — never override)

You may ONLY write to files in these directories:

| Allowed path | Rule |
|---|---|
| `assets/css/styles.css` | The only CSS file you may write to. |
| `lib/zaq_web/` | All Phoenix web-layer modules: function components, LiveViews, layouts, controllers, HEEX templates, etc. Styling and markup only — do not change business logic, assigns, or event handlers unless the user explicitly asked. |

**Explicitly forbidden (read-only — never edit):**
- `assets/css/app.css` — legacy/deprecated; no edits, ever
- `assets/css/foundations.css`, `semantics.css`, `text-styles.css`
- `assets/css/btn.css`, `form.css`, `modal.css`, `table.css`
- `lib/zaq/` and any path outside `lib/zaq_web/` (contexts, schemas, Oban workers, etc.)

If an approved diff line requires touching a file outside these allowed paths, stop and say: "This change requires editing [file], which is outside the allowed directories. Consult the project team before proceeding."

---

## Step 1: Detect Mode

Parse the input after `/design-migrate`:

| Input | Mode |
|---|---|
| A `figma.com` URL | Design-led mode |
| A `figma.com` URL + a file path (e.g. `/design-migrate https://figma.com/... lib/zaq_web/live/bo/people_live.ex`) | Design-led mode, target file known |
| A file path or component name | Audit mode |
| `--audit-all` | Full codebase sweep |
| Nothing | Ask: "Provide a Figma frame URL, a file path, or `--audit-all` for a full sweep." |

---

## Step 2: Read Inputs

**Design-led mode:**
1. Fetch the Figma frame: `mcp__plugin_figma_figma__get_design_context` with the provided URL.
   - If the call fails (permission error, token not configured, etc.), say: "Could not access the Figma frame. Check that the file is shared and your Figma MCP token is configured. Falling back to audit mode." Then proceed as audit mode using the target file path.
2. If no file path was provided alongside the URL, ask: "Which file should this frame be applied to?"
3. Read the target file.

**Audit mode:**
1. Read the target file directly.
2. No Figma frame needed.

**Full sweep (`--audit-all`):**
- Skip to the Full Sweep section below.

**All modes — mandatory read (before Step 3):**

1. Read **`DESIGN.md`** (CSS catalog, token rules, Do's/Don'ts).
2. Read the design-system CSS in two layers below. **Pick classes from the role-specific file first** — do not duplicate btn/form/modal/table patterns in `styles.css`.

**Layer 1 — tokens and typography (constraints and vars)**

| File | What to extract |
|------|-----------------|
| `assets/css/foundations.css` | `--zaq-scale-*` comments (text-only vs layout vs special-purpose); palette vars (never use in templates) |
| `assets/css/semantics.css` | Shape tokens marked “never inline”; semantic color roles (`--zaq-surface-*`, `--zaq-border-*`, `--zaq-text-color-*`) |
| `assets/css/text-styles.css` | `.zaq-text-*` scale mapping; scoping warnings (button label, code-only) |

**Layer 2 — class catalog by UI role (lookup before inventing new classes)**

| File | UI role | Agent writes? |
|------|---------|---------------|
| `assets/css/btn.css` | Buttons — `.zaq-btn-primary`, `.zaq-btn-secondary`, variants | No — read-only. Never reference internal `--zaq-btn-*` vars outside this file |
| `assets/css/form.css` | Form controls — labels, `<select>`, text inputs, combobox triggers/panels (`.zaq-control-*`, `.zaq-field-*`) | No — read-only. Form spacing uses layout scales only (`--zaq-scale-8`, `--zaq-scale-16`) per file comments |
| `assets/css/modal.css` | Modal shell — backdrop, panel (`.zaq-modal`, `.zaq-bo-modal-backdrop`, flush variant) | No — read-only |
| `assets/css/table.css` | Data tables — `.zaq-table` shell, header/body cells, sticky/dense patterns | No — read-only |
| `assets/css/layout.css` | Layout utilities — `.zaq-layout-stack`, `.zaq-layout-inline`, gap modifiers | No — read-only. Prefer over new spacing in `styles.css` |
| `assets/css/styles.css` | **Everything else** — generic BO chrome, cards, feedback, breadcrumbs, feature-composed patterns (e.g. `.zaq-chat-*`), icon sizes (`.zaq-icon-sm/md`), and **new** reusable multi-property utilities when no role file covers the need | **Yes — only writable CSS file** |

Apply the **Token usage constraints** section below. **Comments in source CSS override pixel-size guessing** — e.g. `--zaq-scale-10` is 10px but is **not** a spacing token.

---

## Step 3: Produce Diff Proposal (DO NOT touch any file yet)

Apply the **Invariant Rules** and **Token usage constraints** to determine the correct replacement for each style.

**Pre-proposal gate (required):** For every row that uses a `--zaq-*` token or `.zaq-*` class, verify:

1. **CSS property matches token category** (color vs surface vs border vs scale).
2. **Scale token matches property role** — text-only scales never on `padding` / `margin` / `gap` / `width` / `height` / `border-radius`.
3. **Class scoping** — e.g. `.zaq-btn-text_label-default` only inside buttons; `.zaq-text-code` only on code content.
4. **Shape semantics** — `--zaq-card-*` / `--zaq-border-thickness-*` only inside CSS classes, not inline in templates.
5. **Right catalog file** — btn → `btn.css`; form field/control → `form.css`; modal panel/backdrop → `modal.css`; table/grid list shell → `table.css`; only then `styles.css` for generic or composite patterns. Do not add btn/form/modal/table rules to `styles.css`.

If a row fails any check, **do not propose the wrong token** — use the correct alternative from the constraint tables, or flag `(⚠ constraint — …)` for human decision.

**Human-validation table (required):** After analysis, output a **markdown table** so reviewers can judge each row without opening the file. Every row MUST include at least these columns (additional columns like `Location` or `Flags` are allowed):

| Column | Content |
|--------|---------|
| **UI role** | What this element *is* in the interface (e.g. "page chrome background", "destructive action label", "table header cell", "chat message timestamp"). Not the HTML tag alone — describe purpose for humans. |
| **Existing style** | Current classes, Tailwind utilities, inline styles, or hex/legacy values as they appear in code. |
| **Proposed solution** | Exact replacement: existing **general** class name, feature-scoped class (only if in-scope), or inline `style="..."` with `var(--zaq-*)` per rules. |
| **Token check** | `ok` or `(⚠ …)` — confirms the proposal respects token/class constraints (see **Token usage constraints**). Required on every row. |

Include **`Location`** (`file:line` or `file:line–line`) as the first column whenever possible so approved rows map cleanly to edits.

Example (shape only — adapt rows to the real audit):

| Location | UI role | Existing style | Proposed solution | Token check |
|----------|---------|----------------|-------------------|-------------|
| `bo_layout.ex:142` | Main back-office surface behind content | `bg-white` | `style="background-color: var(--zaq-surface-color-raised)"` | ok |
| `bo_layout.ex:143` | Secondary body copy in sidebar | `text-[0.82rem]` | `.zaq-text-body-sm` | ok |
| `bo_layout.ex:198` | Accent focus ring on nav | `#03b6d4` | `--zaq-border-color-accent` on appropriate property via token-safe class or inline per property | ok |
| `bo_layout.ex:220` | Inline monospace snippet | `font-mono text-xs` | `.zaq-text-code` or `.zaq-text-caption` (pick by visual density) | ok |
| `bo_layout.ex:512` | Error state helper text | `text-red-600` | `.zaq-text-body-sm` + `style="color: var(--zaq-text-color-body-danger)"` or `(⚠ keep legacy — human decide)` | ok |
| `some_live.ex:88` | Toolbar row gap | `gap-2.5` / `p-[10px]` | `.zaq-text-caption` for copy; for spacing use `--zaq-scale-8` or `(layout — keep)` — **never** `var(--zaq-scale-10)` on gap/padding | `(⚠ scale-10 is text-only)` |

Optional compact appendix: one-line `file:line  existing → proposed  (reason)` duplicates are fine for grep-friendly logs, but the **table is the source of truth** for approval.

**Class selection discipline (summary — see Invariant Rules):** Match **UI role → CSS file** (btn / form / modal / table / styles). Prefer existing classes from the role file before minting new ones in `styles.css`. Use **feature-prefixed** classes (e.g. `.zaq-chat-*`) **only** inside that feature's templates/components. If the migration is **only** text `color` or surface `background-color` / `bg-*`, use **inline** `style="..."` with the correct `--zaq-*` token — do not add a one-off class in `styles.css`.

**Figma scope boundary (design-led mode only):** The proposal covers styling only — token and class replacements. If the Figma frame shows different text content, different icons, different component structure, or different layout from the current code, note them as observations below the table ("ℹ Figma shows X, current code has Y") but do NOT include them in the table and do NOT propose code changes for them. Content and structure differences are outside the scope of this skill.

Mark ambiguous text scale choices with `(⚠ ambiguous — override if needed)` in **Proposed solution** or a **Flags** column.

Present the full validation table (and optional appendix). Then ask: "Approve all, or list line numbers / table rows to reject/override."

**Wait for user response before proceeding. Do not touch any file.**

---

## Step 4: Apply Changes and Verify

Apply only the approved table rows (or line overrides the user gave). Write to:

- `assets/css/styles.css` — **only when** the approved solution is a **new reusable class** (multi-property layout, repeated component pattern, or non-trivial bundle that inline would duplicate everywhere). **Do not** add a class when the approved row is a **general existing class** swap or a **color-only** inline `style="color: var(...)"` / `style="background-color: var(...)"`.
  ```css
  /* <description of role> */
  .<class-name> {
    <property>: var(--zaq-<semantic-token>);
  }
  ```
- `lib/zaq_web/...` — the target file (component, LiveView, layout, etc.) — prefer **general** classes and **inline color vars** per Step 3 / Invariant Rules.

Then run:

```bash
mix format
```

### Targeted e2e verification

After `mix format` passes, run a targeted smoke test:

1. **Pick LiveView(s) to cover the change:**
   - If the edited file is already a LiveView under `lib/zaq_web/live/`, use that file only.
   - Otherwise, find LiveViews that reference the edited component:
   ```bash
   grep -rl "ComponentModuleName\b" lib/zaq_web/live/ 2>/dev/null
   ```
   Replace `ComponentModuleName` with the Elixir module name of the edited component (e.g. `BOLayout`, `SearchableSelect`, `BOModal`).

2. **Derive the feature slug from each matching LiveView path:**
   - `lib/zaq_web/live/bo/people_live.ex` → slug: `people`
   - `lib/zaq_web/live/bo/agents_live.ex` → slug: `agents`
   - Pattern: take the filename, strip `_live.ex`, use the base name as the slug.

3. **Check whether a spec file exists for each slug:**
   ```bash
   ls test/e2e/specs/<slug>.spec.js
   ```

4. **Run the matching spec(s) only:**
   ```bash
   cd test/e2e && npx playwright test specs/<slug>.spec.js
   ```
   Report pass/fail. If any test fails, do not proceed to Step 5 — report the failure and wait for instructions.

**Special cases:**
- **`bo_layout.ex` or any component used by all BO pages:** Run `agents.spec.js` as the representative smoke test only.
   ```bash
   cd test/e2e && npx playwright test specs/agents.spec.js
   ```
- **No matching spec found:** Say: "No matching e2e spec found for this change. Visual verification in the running app is sufficient." Skip e2e and proceed to Step 5.

Mark this target file as `approved` in your in-conversation ledger.

---

## Step 5: Confirm PR Readiness

Say: "Changes applied and verified. **Developer gate:** run `mix q` before opening the PR. Files changed:
- [list every file touched]"

---

## Batching Multiple Components

You can produce diff proposals for several components before applying any of them. After Step 4, a component is `approved`.

Maintain an explicit in-conversation ledger and reprint it after each state change:

```
Pending:  [component A, component B]
Approved: [component C]
```

To batch-apply: when the user is ready to ship, list all `pending` items, confirm, then run Step 4 for each in one pass. Run `mix format` once across the full batch, then open one PR.

Batching is session-scoped — there is no persistent state file.

---

## Full Sweep (`--audit-all`)

Sweep all files under `lib/zaq_web/`. Do NOT flag violations inside `assets/css/` files — those are the token source files, not templates. Include `assets/css/app.css` only to identify deprecated utility class definitions that can eventually be removed.

For each file, flag violations by severity:

```
CRITICAL  hardcoded hex/rgb, foundation vars used in templates
CRITICAL  text-only --zaq-scale-* (10, 12, 14, 20) used for padding/margin/gap/width/height/radius
HIGH      app.css deprecated classes (.zaq-bg-*, .zaq-text-accent, .zaq-border-*, etc.)
HIGH      semantic shape tokens (--zaq-card-*, --zaq-border-thickness-*) inlined in templates
HIGH      scoped text class used outside scope (.zaq-btn-text_label-default outside btn, etc.)
MEDIUM    Tailwind color/typography classes (text-sm, bg-white, text-gray-*, font-mono)
LOW       Tailwind layout classes (no action needed)
```

Before writing output, check whether `docs/exec-plans/migration-backlog.md` already exists. If it does, ask: "A backlog file already exists. Overwrite it or append a new timestamped section?" Wait for confirmation.

Write (or append) to `docs/exec-plans/migration-backlog.md` in this format (each bullet should be scannable; include **UI role**, **Existing style**, and **Proposed** like the Step 3 table when space allows):

```markdown
# Design Migration Backlog
Generated: <date>

## CRITICAL
- `bo_layout.ex:198` — **UI role:** focus ring accent — **Existing:** `#03b6d4` — **Proposed:** `border-color: var(--zaq-border-color-accent)` (inline or class per rules)

## HIGH
- `bo_layout.ex:201` — **UI role:** dark ink surface — **Existing:** `.zaq-bg-ink` (app.css) — **Proposed:** `var(--zaq-surface-color-base)` or matching semantic surface token per DESIGN.md

## MEDIUM
- `bo_layout.ex:220` — **UI role:** compact monospace — **Existing:** `font-mono text-xs` — **Proposed:** `.zaq-text-caption`

## LOW (no action needed)
- ...
```

Then say: "Backlog written to `docs/exec-plans/migration-backlog.md`. Run `/design-migrate <file>` to start migrating any entry."

---

## Token usage constraints (mandatory — cannot be overridden)

**Source of truth:** inline comments in `foundations.css`, `semantics.css`, and `text-styles.css`. Re-read when adding new tokens.

### Scale tokens — three roles (never mix)

| Role | Tokens | Allowed CSS properties | How to apply in migrations |
|------|--------|------------------------|----------------------------|
| **Text-only** | `--zaq-scale-10`, `--zaq-scale-12`, `--zaq-scale-14`, `--zaq-scale-20` | **`font-size` only**, and only via `.zaq-text-*` in `text-styles.css` — not raw in templates | Use `.zaq-text-caption`, `.zaq-text-body-sm`, `.zaq-text-body`, `.zaq-text-h2`, etc. **Never** `padding`/`margin`/`gap`/`width`/`height`/`border-radius` with these vars |
| **Special-purpose** | `--zaq-scale-1` (border thickness), `--zaq-scale-999` (pill radius), `--zaq-scale-1440` (max-width) | Matching property only | `--zaq-scale-1` → `border-width` / `outline-width`; `--zaq-scale-999` → full pill `border-radius`; `--zaq-scale-1440` → `max-width` |
| **Layout (8px grid)** | `--zaq-scale-0`, `--zaq-scale-2`, `--zaq-scale-4`, `--zaq-scale-8`, `--zaq-scale-16`, `--zaq-scale-24`, `--zaq-scale-32`, `--zaq-scale-40`, `--zaq-scale-48`, `--zaq-scale-56`, `--zaq-scale-64`, `--zaq-scale-72`, `--zaq-scale-80`, `--zaq-scale-88`, `--zaq-scale-96`, `--zaq-scale-120` | `padding`, `margin`, `gap`, `width`, `height`, `border-radius`, `outline-offset`, etc. | Use in **new** `styles.css` classes when spacing is reused; do not pick by pixel coincidence |

**Common agent mistake:** mapping `p-2.5`, `gap-[10px]`, or `text-[10px]` to `var(--zaq-scale-10)` for spacing or sizing. **Wrong.** `--zaq-scale-10` exists for BO caption **typography** (`.zaq-text-caption`), not layout.

**20px spacing (`p-5`, `gap-5`, `m-5`):** there is **no** layout scale token at 20px (`--zaq-scale-20` is header **text**). Flag `(⚠ 20px spacing — no layout token; keep Tailwind or request token)` — do not reuse `--zaq-scale-20`.

### Semantic shape tokens — classes only

From `semantics.css` — **never inline in HEEX/templates**:

- `--zaq-card-gap-default`, `--zaq-card-padding-default`, `--zaq-card-radius-default`
- `--zaq-border-thickness-default`

Compose via existing classes (e.g. `.zaq-card-default`) or add a reusable class in `styles.css`.

### Class scoping (from `text-styles.css`)

| Class | Scope |
|-------|-------|
| `.zaq-btn-text_label-default` | Inside `.zaq-btn*` / button elements only |
| `.zaq-text-code`, `.zaq-text-pre` | Code / preformatted content only — not body copy or headings |
| `.zaq-chat-*` (in `styles.css`) | Chat feature LiveViews/components only |

### Quick validation (run on every proposed token)

```
IF property IN (padding, margin, gap, width, height, min-*, max-* except 1440, border-radius)
  AND token IN (--zaq-scale-10, --zaq-scale-12, --zaq-scale-14, --zaq-scale-20)
  → REJECT — flag (⚠ text-only scale misused)

IF property = font-size AND value is a scale var
  → REJECT inline font-size — use .zaq-text-* class instead

IF token starts with --zaq-card- OR token = --zaq-border-thickness-default
  AND location is template/LiveView inline style
  → REJECT — use styles.css class
```

---

## Invariant Rules (embedded — cannot be overridden)

Apply styles in this exact order:

1. **Use an existing class** — look up by UI role (read-only sources; only `styles.css` is writable):

   | UI role | Look in first |
   |---------|----------------|
   | Button | `btn.css` — `.zaq-btn-primary`, `.zaq-btn-secondary`, etc. |
   | Form label, input, select, combobox | `form.css` — `.zaq-control-*`, `.zaq-field-*` |
   | Modal backdrop / panel | `modal.css` — `.zaq-modal`, `.zaq-bo-modal-backdrop` |
   | Data table / dense list grid | `table.css` — `.zaq-table` and related |
   | Layout spacing (stack, inline, gaps) | `layout.css` — `.zaq-layout-*` |
   | Typography | `text-styles.css` — `.zaq-text-*` |
   | Generic chrome, cards, feedback, composites | `styles.css` — `.zaq-card-*`, `.zaq-border-*`, feature patterns |
   | Token vars (inline color only) | `semantics.css` — never foundation vars |

   Classes in `app.css` are off-limits — legacy/deprecated. **Never** reference `--zaq-btn-*` internal vars outside `btn.css`.

   **General vs feature-scoped naming:** Prefer **general** utilities whose names describe a **reusable semantic role** across the app (e.g. `.zaq-text-*`, `.zaq-select*`, shared surface/card patterns). Use those before inventing component-local classes. **Feature-prefixed** classes (e.g. `.zaq-chat-*`) apply **only** inside that feature's LiveViews/components — do not use `.zaq-chat-*` outside chat, and do not introduce new `zaq-<feature>-*` classes outside their feature unless the design system already exposes them as shared primitives.

2. **Buttons** → classes from `btn.css` only (`.zaq-btn-primary`, `.zaq-btn-secondary`, documented variants). No new button styles in `styles.css`.

3. **Form controls** → classes from `form.css` only. No ad-hoc input/select styling in templates or `styles.css` when a `.zaq-control-*` / `.zaq-field-*` class exists or fits.

4. **Modals** → shell classes from `modal.css`. Page-specific modal *content* layout may use `styles.css`; do not re-define backdrop/panel chrome elsewhere.

5. **Tables** → shell and cell patterns from `table.css`. Do not duplicate `.zaq-table` rules in `styles.css`.

6. **Text** → closest `.zaq-text-*` from `text-styles.css`. No `text-sm`, `text-lg`, `text-[*]`, no inline `font-size`, no raw `var(--zaq-scale-10|12|14|20)` in templates.
   Text decorations (`uppercase`, `underline`, `tracking-*`) are allowed alongside a `.zaq-text-*` base.
   Those four scale tokens are **typography-only** (see **Token usage constraints**).

7. **Color-only migrations (text or surface):** If the **only** change needed is `color` or `background-color` / `bg-*` mapping to a semantic `--zaq-*` token, use **inline** `style="color: var(--zaq-...)"` or `style="background-color: var(--zaq-...)"` (property-appropriate token — see table below). **Do not** create a dedicated class in `styles.css` for a one-property color swap.

8. **New class needed** → add to `styles.css` **only** when no class in btn / form / modal / table / text-styles fits **and** inline would duplicate a **multi-property** or **repeated** pattern across many nodes. Never `app.css`. Never duplicate role-file patterns in `styles.css`.

9. **No class fits (non-color-only)** → semantic var inline: `--zaq-surface-color-*`, `--zaq-text-color-*`, `--zaq-border-color-*`.
   Never foundation vars (`--zaq-color-blue-*`, `--zaq-color-neutral-*`, `--zaq-color-black-*`).

   **Token role must match CSS property — never cross categories:**

   | Token prefix | Use only for |
   |---|---|
   | `--zaq-surface-color-*` | `background` / `background-color` only |
   | `--zaq-border-color-*` | `border-color` / `border` / `outline` only |
   | `--zaq-text-color-body-*` | `color` (text) only |

   If no token exists for the correct role (e.g. need destructive text color): use `--zaq-text-color-body-danger` — never `error` naming. Mark `(⚠ no token for this role — keep legacy or request new token)` when no semantic token fits.

10. **Tailwind color and typography** → never use. Layout/spacing Tailwind utilities are allowed only as described in Rule 11 below.

11. **Spacing & sizing** — flag all padding, margin, gap, width, height, and border-radius Tailwind utilities in the proposal table. Propose one of:
   - **Replace with existing general class** if `.zaq-card-default` or another shared pattern already covers the role (avoid new `.zaq-<page>-*` classes for one-off wrappers when a general primitive exists).
   - **Create new class in `styles.css`** using **layout** `var(--zaq-scale-*)` tokens only (see **Token usage constraints**) when spacing is **reused** across multiple nodes — not for a single unique gap on one toolbar.
   - **Keep as Tailwind layout utility** (`(layout — keep)`) when the value is one-off sizing with no semantic role (e.g. `w-10 h-10` on an icon button, `p-8` on a page wrapper).
   - **Flag arbitrary values** (`px-[9px]`, `py-[7px]`, `top-[0.5px]`, etc.) as `(⚠ arbitrary spacing — needs design decision)` — do not replace automatically.
   - **Never** map spacing to **text-only** scale tokens (`--zaq-scale-10`, `12`, `14`, `20`) even when the px value matches.

   Tailwind → **layout** scale token reference (spacing / radius only — **not** typography):

   | Tailwind class | px | Layout token |
   |---|---|---|
   | p-1 / m-1 / gap-1 | 4px | `--zaq-scale-4` |
   | p-2 / m-2 / gap-2 | 8px | `--zaq-scale-8` |
   | p-3 / m-3 / gap-3 | 12px | `(⚠ 12px layout — no layout token; use --zaq-scale-8 or --zaq-scale-16 or keep Tailwind)` — **not** `--zaq-scale-12` |
   | p-4 / m-4 / gap-4 | 16px | `--zaq-scale-16` |
   | p-5 / m-5 / gap-5 | 20px | `(⚠ 20px layout — no layout token; keep Tailwind or request token)` — **not** `--zaq-scale-20` |
   | p-6 / m-6 / gap-6 | 24px | `--zaq-scale-24` |
   | p-8 / m-8 / gap-8 | 32px | `--zaq-scale-32` |
   | rounded | 4px | `--zaq-scale-4` |
   | rounded-lg | 8px | `--zaq-scale-8` |
   | rounded-xl | 12px | `(⚠ see p-3 row — not --zaq-scale-12 for new migrations)` |
   | rounded-2xl | 16px | `--zaq-scale-16` |
   | rounded-full | 999px | `--zaq-scale-999` |

   Tailwind typography → **`.zaq-text-*` class** (never raw `--zaq-scale-*` for `font-size` in templates):

   | Visual need | Class (uses text-only scale internally) |
   |---|---|
   | 10px BO meta / caption | `.zaq-text-caption` |
   | 12px small body / table | `.zaq-text-body-sm` |
   | 14px default body | `.zaq-text-body` |
   | 20px section heading | `.zaq-text-h2` |

### Text scale reference

| Role | Class |
|---|---|
| Heading | `.zaq-text-h1` → `.zaq-text-h5` |
| Body large | `.zaq-text-body-lg` |
| Body default | `.zaq-text-body` |
| Body small / table | `.zaq-text-body-sm` |
| Meta / compact labels | `.zaq-text-caption` |
| Code | `.zaq-text-code` |
| Pre block | `.zaq-text-pre` |
| Button label | `.zaq-btn-text_label-default` |

When ambiguous between adjacent scales, prefer the smaller one. Map by visual role, not pixel size.

### CSS file write permissions

| File | Role | Agent can write? |
|---|---|---|
| `styles.css` | Generic BO chrome, composites, new reusable utilities | Yes — only when rules require a new multi-property / repeated pattern (not color-only swaps) |
| `btn.css` | Buttons | No |
| `form.css` | Form controls | No |
| `modal.css` | Modal shell | No |
| `table.css` | Data tables | No |
| `app.css` | Legacy | No |
| `semantics.css` | Semantic tokens | No |
| `text-styles.css` | Typography classes | No |
| `foundations.css` | Foundation tokens | No |

### Forbidden patterns

- Any class from `app.css`
- Hardcoded hex, rgb, oklch, or hsl values in templates
- Foundation vars in templates
- Tailwind color or typography classes
- daisyUI component classes in BO templates
- **Text-only scale tokens** (`--zaq-scale-10`, `12`, `14`, `20`) on layout properties (padding, margin, gap, width, height, border-radius)
- **Inline `font-size: var(--zaq-scale-*)`** in templates — use `.zaq-text-*` instead
- **Inline semantic shape tokens** (`--zaq-card-*`, `--zaq-border-thickness-default`) in templates
- **Scoped classes outside scope** (`.zaq-btn-text_label-default` outside buttons, `.zaq-text-code` on non-code copy)
- **Role-file duplication** — new btn/form/modal/table styling in `styles.css` when the element belongs in `btn.css`, `form.css`, `modal.css`, or `table.css`
- **`--zaq-btn-*` vars** referenced outside `btn.css`
