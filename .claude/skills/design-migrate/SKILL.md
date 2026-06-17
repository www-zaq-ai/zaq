---
name: design-migrate
description: Migrate ZAQ web UI (components, LiveViews, layouts) styling to the --zaq-* token system. Accepts a Figma frame URL (design-led), a file path (audit), or --audit-all (full sweep). Always outputs a human-validation table (UI role, existing style, proposed solution) before touching any file. Prefers general semantic classes and inline color vars over new CSS. Full sweep mode writes a backlog file directly.
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

**Explicitly forbidden:**
- `assets/css/app.css` — no edits, ever
- `assets/css/foundations.css`, `semantics.css`, `text-styles.css`, `btn.css` — read-only
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

---

## Step 3: Produce Diff Proposal (DO NOT touch any file yet)

Apply the **Invariant Rules** (see bottom of this file) to determine the correct replacement for each style.

**Human-validation table (required):** After analysis, output a **markdown table** so reviewers can judge each row without opening the file. Every row MUST include at least these columns (additional columns like `Location` or `Flags` are allowed):

| Column | Content |
|--------|---------|
| **UI role** | What this element *is* in the interface (e.g. "page chrome background", "destructive action label", "table header cell", "chat message timestamp"). Not the HTML tag alone — describe purpose for humans. |
| **Existing style** | Current classes, Tailwind utilities, inline styles, or hex/legacy values as they appear in code. |
| **Proposed solution** | Exact replacement: existing **general** class name, feature-scoped class (only if in-scope), or inline `style="..."` with `var(--zaq-*)` per rules. |

Include **`Location`** (`file:line` or `file:line–line`) as the first column whenever possible so approved rows map cleanly to edits.

Example (shape only — adapt rows to the real audit):

| Location | UI role | Existing style | Proposed solution |
|----------|---------|----------------|-------------------|
| `bo_layout.ex:142` | Main back-office surface behind content | `bg-white` | `style="background-color: var(--zaq-surface-color-raised)"` (color-only → inline var) |
| `bo_layout.ex:143` | Secondary body copy in sidebar | `text-[0.82rem]` | `.zaq-text-body-sm` |
| `bo_layout.ex:198` | Accent focus ring on nav | `#03b6d4` | `--zaq-border-color-accent` on appropriate property via token-safe class or inline per property |
| `bo_layout.ex:220` | Inline monospace snippet | `font-mono text-xs` | `.zaq-text-code` or `.zaq-text-caption` (pick by visual density) |
| `bo_layout.ex:512` | Error state helper text | `text-red-600` | `(⚠ no --zaq-text-color-error — keep legacy or request token)` — never use `--zaq-border-color-*` for `color` |

Optional compact appendix: one-line `file:line  existing → proposed  (reason)` duplicates are fine for grep-friendly logs, but the **table is the source of truth** for approval.

**Class selection discipline (summary — see Invariant Rules):** Prefer existing **general** semantic utilities (e.g. `.zaq-text-*`, `.zaq-select*`, shared cards/surfaces) so you do not mint a new class per element. Use **feature-prefixed** classes (e.g. `.zaq-chat-*`) **only** inside that feature's templates/components. If the migration is **only** text `color` or surface `background-color` / `bg-*`, use **inline** `style="..."` with the correct `--zaq-*` token — do not add a one-off class in `styles.css`.

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
HIGH      app.css deprecated classes (.zaq-bg-*, .zaq-text-accent, .zaq-border-*, etc.)
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
- `bo_layout.ex:201` — **UI role:** dark ink surface — **Existing:** `.zaq-bg-ink` (app.css) — **Proposed:** `var(--zaq-surface-color-dark)` / matching general class

## MEDIUM
- `bo_layout.ex:220` — **UI role:** compact monospace — **Existing:** `font-mono text-xs` — **Proposed:** `.zaq-text-caption`

## LOW (no action needed)
- ...
```

Then say: "Backlog written to `docs/exec-plans/migration-backlog.md`. Run `/design-migrate <file>` to start migrating any entry."

---

## Invariant Rules (embedded — cannot be overridden)

Apply styles in this exact order:

1. **Use an existing class** from `styles.css`, `semantics.css`, `text-styles.css`, or `btn.css` (read-only look-up sources — only `styles.css` is writable).
   Classes in `app.css` are off-limits — legacy/deprecated.

   **General vs feature-scoped naming:** Prefer **general** utilities whose names describe a **reusable semantic role** across the app (e.g. `.zaq-text-*`, `.zaq-select*`, shared surface/card patterns). Use those before inventing component-local classes. **Feature-prefixed** classes (e.g. `.zaq-chat-*`) apply **only** inside that feature's LiveViews/components — do not use `.zaq-chat-*` outside chat, and do not introduce new `zaq-<feature>-*` classes outside their feature unless the design system already exposes them as shared primitives.

2. **Buttons** → `.zaq-btn-primary` or `.zaq-btn-secondary` only. No new button styles.

3. **Text** → closest `.zaq-text-*` from `text-styles.css`. No `text-sm`, `text-lg`, `text-[*]`, no font vars.
   Text decorations (`uppercase`, `underline`, `tracking-*`) are allowed alongside a `.zaq-text-*` base.

4. **Color-only migrations (text or surface):** If the **only** change needed is `color` or `background-color` / `bg-*` mapping to a semantic `--zaq-*` token, use **inline** `style="color: var(--zaq-...)"` or `style="background-color: var(--zaq-...)"` (property-appropriate token — see table below). **Do not** create a dedicated class in `styles.css` for a one-property color swap.

5. **New class needed** → add to `styles.css` only when no general class fits **and** inline would duplicate a **multi-property** or **repeated** pattern across many nodes. Never `app.css`.

6. **No class fits (non-color-only)** → semantic var inline: `--zaq-surface-color-*`, `--zaq-text-color-*`, `--zaq-border-color-*`.
   Never foundation vars (`--zaq-color-blue-*`, `--zaq-color-neutral-*`, `--zaq-color-black-*`).

   **Token role must match CSS property — never cross categories:**

   | Token prefix | Use only for |
   |---|---|
   | `--zaq-surface-color-*` | `background` / `background-color` only |
   | `--zaq-border-color-*` | `border-color` / `border` / `outline` only |
   | `--zaq-text-color-body-*` | `color` (text) only |

   If no token exists for the correct role (e.g. need a text-error color but only `--zaq-border-color-error` exists): **do not use the wrong-category token**. Mark the table row / appendix line as `(⚠ no token for this role — keep legacy or request new token)` and leave the decision to the human.

7. **Tailwind color and typography** → never use. Layout/spacing Tailwind utilities are allowed only as described in Rule 8 below.

8. **Spacing & sizing** — flag all padding, margin, gap, width, height, and border-radius Tailwind utilities in the proposal table. Propose one of:
   - **Replace with existing general class** if `.zaq-card-default` or another shared pattern already covers the role (avoid new `.zaq-<page>-*` classes for one-off wrappers when a general primitive exists).
   - **Create new class in `styles.css`** using `var(--zaq-scale-*)` only when spacing is **reused** across multiple nodes or states and no general class covers it — not for a single unique gap on one toolbar.
   - **Keep as Tailwind layout utility** (`(layout — keep)`) when the value is one-off sizing with no semantic role (e.g. `w-10 h-10` on an icon button, `p-8` on a page wrapper).
   - **Flag arbitrary values** (`px-[9px]`, `py-[7px]`, `top-[0.5px]`, etc.) as `(⚠ arbitrary spacing — needs design decision)` — do not replace automatically.

   Tailwind → scale token reference:

   | Tailwind class | px | Token |
   |---|---|---|
   | p-1 / m-1 / gap-1 | 4px | `--zaq-scale-4` |
   | p-2 / m-2 / gap-2 | 8px | `--zaq-scale-8` |
   | p-3 / m-3 / gap-3 | 12px | `--zaq-scale-12` |
   | p-4 / m-4 / gap-4 | 16px | `--zaq-scale-16` |
   | p-5 / m-5 / gap-5 | 20px | `--zaq-scale-20` |
   | p-6 / m-6 / gap-6 | 24px | `--zaq-scale-24` |
   | p-8 / m-8 / gap-8 | 32px | `--zaq-scale-32` |
   | rounded | 4px | `--zaq-scale-4` |
   | rounded-lg | 8px | `--zaq-scale-8` |
   | rounded-xl | 12px | `--zaq-scale-12` |
   | rounded-2xl | 16px | `--zaq-scale-16` |
   | rounded-full | 999px | `--zaq-scale-999` |

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

| File | Agent can write? |
|---|---|
| `styles.css` | Yes — new semantic utility classes **only when** rules require a reusable multi-property / repeated pattern (not for pure color-only swaps — use inline vars) |
| `app.css` | No |
| `semantics.css` | No |
| `text-styles.css` | No |
| `btn.css` | No |
| `foundations.css` | No |

### Forbidden patterns

- Any class from `app.css`
- Hardcoded hex, rgb, oklch, or hsl values in templates
- Foundation vars in templates
- Tailwind color or typography classes
- daisyUI component classes in BO templates
