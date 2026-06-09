---
name: design-migrate
description: Migrate ZAQ component or page styling to the --zaq-* token system. Accepts a Figma frame URL (design-led), a file path (audit), or --audit-all (full sweep). Always produces a diff proposal before modifying app templates. Full sweep mode writes a backlog file directly.
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
| `assets/css/styles.css` | The only CSS file you may write to. All other CSS files are read-only. |
| `lib/zaq_web/components/` | Shared component files only. No LiveView pages, no routers, no contexts. |
| `storybook/` | Storybook story files only. |

**Explicitly forbidden:**
- `assets/css/app.css` — no edits, ever
- `assets/css/foundations.css`, `semantics.css`, `text-styles.css`, `btn.css` — read-only
- `lib/zaq_web/live/` — no LiveView page files
- Any file outside the three allowed directories above

If an approved diff line requires touching a file outside these directories, stop and say: "This change requires editing [file], which is outside the allowed directories. Consult the project team before proceeding."

---

## Step 1: Detect Mode

Parse the input after `/design-migrate`:

| Input | Mode |
|---|---|
| A `figma.com` URL | Design-led mode |
| A `figma.com` URL + a file path (e.g. `/design-migrate https://figma.com/... lib/zaq_web/components/bo_layout.ex`) | Design-led mode, target file known |
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

Apply the **Invariant Rules** (see bottom of this file) to determine the correct replacement for each style. Use the class-first lookup in Rule 1 before falling back to semantic vars.

Analyse every style in the target file and produce a complete diff proposal in this exact format:

```
<file>:<line>  <current-value>              → <proposed-replacement>        (<reason>)
```

Examples:
```
bo_layout.ex:142  bg-white                  → --zaq-surface-color-raised    (no class for this role)
bo_layout.ex:143  text-[0.82rem]            → .zaq-text-body-sm              (class exists, use it)
bo_layout.ex:198  #03b6d4                   → --zaq-border-color-accent      (BLOCKED: hardcoded hex)
bo_layout.ex:201  .zaq-bg-ink               → --zaq-surface-color-dark       (app.css class, off-limits)
bo_layout.ex:220  font-mono text-xs         → .zaq-text-caption              (closest text role)
bo_layout.ex:310  <.button>                 → .zaq-btn-primary               (replace with btn.css class)
```

Mark ambiguous text scale choices with `(⚠ ambiguous — override if needed)`.

Present the full diff. Then ask: "Approve all, or list line numbers to reject/override."

**Wait for user response before proceeding. Do not touch any file.**

---

## Step 4: Stage in CSS and Storybook Only (DO NOT modify the app template yet)

Apply only the lines the user approved. Touch **two things only** — not the app template:

1. **`assets/css/styles.css`** — if any approved line requires a new utility class that doesn't exist yet. Add the new class following this pattern:
   ```css
   /* <description of role> */
   .<class-name> {
     <property>: var(--zaq-<semantic-token>);
   }
   ```
   Never add to `app.css`. The four source files (`semantics.css`, `text-styles.css`, `btn.css`, `styles.css`) are look-up sources — only `styles.css` is writable.

2. **The Storybook story** for the target component.
   - If the target is a layout file (any file matching `*_layout.ex`, `*_layout.html.heex`, `root.html.heex`): skip Storybook story creation and note it in your output — layout files have no 1:1 Storybook story.
   - Otherwise: update the existing story or create one at `storybook/components/<category>/<component_name>.story.exs` using the pattern from an existing story (e.g. `storybook/components/misc/header.story.exs`).

Mark this component as `staged` in your in-conversation ledger (see Batching section).

Then say: "Changes staged in Storybook. Run `mix storybook` and review visually. Reply `approved` when ready or describe what needs adjusting."

**Wait for visual approval before proceeding.**

---

## Step 5: Apply to App Template

Apply the same approved changes to the actual app template file(s).

Then run verification from the project root:

```bash
cd /path/to/project && bash style-guard.sh
mix format
```

Report results. If `style-guard.sh` fails, show the failing lines and fix them before proceeding.

### Targeted e2e verification

After `style-guard.sh` and `mix format` pass, run a targeted smoke test:

1. **Identify which LiveViews use the edited component:**
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
   Report pass/fail. If any test fails, do not proceed to Step 6 — report the failure and wait for instructions.

**Special cases:**
- **`bo_layout.ex` or any component used by all BO pages:** Run `agents.spec.js` as the representative smoke test only.
   ```bash
   cd test/e2e && npx playwright test specs/agents.spec.js
   ```
- **No matching spec found:** Say: "No matching e2e spec found for this component. Storybook visual verification is sufficient." Skip e2e and proceed to Step 6.
- **Storybook story was created or updated in Step 4:** Also run:
   ```bash
   mix storybook
   ```
   Report pass/fail.

Mark this component as `approved` in your in-conversation ledger.

---

## Step 6: Confirm PR Readiness

Say: "Changes applied and verified. **Developer gate:** run `mix q` before opening the PR. Files changed:
- [list every file touched]"

---

## Batching Multiple Components

You can migrate several components in one session before applying any of them to the app. After Step 4, a component is `staged`. After Step 5, it is `approved`.

Maintain an explicit in-conversation ledger and reprint it after each state change:

```
Staged:   [component A, component B]
Approved: [component C]
```

To batch-apply: when the user is ready to ship, list all `staged` items, confirm, then run Step 5 for each in one pass. Run `style-guard.sh` and `mix format` once across the full batch, then open one PR.

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

Write (or append) to `docs/exec-plans/migration-backlog.md` in this format:

```markdown
# Design Migration Backlog
Generated: <date>

## CRITICAL
- `bo_layout.ex:198` — #03b6d4 hardcoded → --zaq-border-color-accent

## HIGH
- `bo_layout.ex:201` — .zaq-bg-ink (app.css) → --zaq-surface-color-dark

## MEDIUM
- `bo_layout.ex:220` — font-mono text-xs → .zaq-text-caption

## LOW (no action needed)
- ...
```

Then say: "Backlog written to `docs/exec-plans/migration-backlog.md`. Run `/design-migrate <file>` to start migrating any entry."

---

## Invariant Rules (embedded — cannot be overridden)

Apply styles in this exact order:

1. **Use an existing class** from `styles.css`, `semantics.css`, `text-styles.css`, or `btn.css` (read-only look-up sources — only `styles.css` is writable).
   Classes in `app.css` are off-limits — legacy/deprecated.
2. **Buttons** → `.zaq-btn-primary` or `.zaq-btn-secondary` only. No new button styles.
3. **Text** → closest `.zaq-text-*` from `text-styles.css`. No `text-sm`, `text-lg`, `text-[*]`, no font vars.
   Text decorations (`uppercase`, `underline`, `tracking-*`) are allowed alongside a `.zaq-text-*` base.
4. **New class needed** → add to `styles.css` only. Never `app.css`.
5. **No class fits** → semantic var inline: `--zaq-surface-color-*`, `--zaq-text-color-*`, `--zaq-border-color-*`.
   Never foundation vars (`--zaq-color-blue-*`, `--zaq-color-neutral-*`, `--zaq-color-black-*`).
6. **Tailwind** → layout/spacing fallback only. Never color. Never typography.

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
| `styles.css` | Yes — new semantic utility classes only |
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
