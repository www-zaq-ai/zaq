---
name: design-migrate
description: Migrate ZAQ component or page styling to the --zaq-* token system. Accepts a Figma frame URL (design-led), a file path (audit), or --audit-all (full sweep). Always produces a diff proposal before touching any file.
trigger: when the user types /design-migrate
---

# Design Migrate Skill

You are migrating ZAQ's styling incrementally to the `--zaq-*` token system.

**Announce at start:** "Using /design-migrate — [detecting mode from input]"

---

## Step 1: Detect Mode

Parse the input after `/design-migrate`:

| Input | Mode |
|---|---|
| A `figma.com` URL | Design-led mode |
| A file path or component name | Audit mode |
| `--audit-all` | Full codebase sweep |
| Nothing | Ask: "Provide a Figma frame URL, a file path, or `--audit-all` for a full sweep." |

---

## Step 2: Read Inputs

**Design-led mode:**
1. Fetch the Figma frame: `mcp__plugin_figma_figma__get_design_context` with the provided URL
2. Ask the user: "Which file should this frame be applied to?" if not already provided
3. Read the target file

**Audit mode:**
1. Read the target file directly
2. No Figma frame needed

**Full sweep (`--audit-all`):**
- Skip to the Full Sweep section below

---

## Step 3: Produce Diff Proposal (DO NOT touch any file yet)

Analyse every style in the target file against the invariant rules below. Produce a complete diff proposal in this exact format:

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

**Wait for user response before proceeding.**

---

## Step 4: Apply Approved Changes — CSS and Storybook Only

Apply only the lines the user approved. Touch two things only:

1. **`assets/css/styles.css`** — if any approved line requires a new utility class that doesn't exist yet. Add the new class following this pattern:
   ```css
   /* <description of role> */
   .<class-name> {
     <property>: var(--zaq-<semantic-token>);
   }
   ```
   Never add to `app.css`.

2. **The Storybook story** for the target component. If the story doesn't exist yet, create one at `storybook/components/<category>/<component_name>.story.exs` using the pattern from an existing story (e.g. `storybook/components/misc/header.story.exs`).

Then say: "Changes staged in Storybook. Run `mix storybook` and review visually. Reply `approved` when ready or describe what needs adjusting."

**Wait for visual approval before proceeding.**

---

## Step 5: Apply to App Template

Apply the same approved changes to the actual app template file(s).

Then run verification:

```bash
bash style-guard.sh
mix format
```

Report results. If `style-guard.sh` fails, show the failing lines and fix them before proceeding.

---

## Step 6: Confirm PR Readiness

Say: "Changes applied and verified. Run `mix q` before opening the PR. Files changed:
- [list every file touched]"

---

## Full Sweep (`--audit-all`)

Sweep all files under `lib/zaq_web/` and `assets/css/`. For each file, flag violations by severity:

```
CRITICAL  hardcoded hex/rgb, foundation vars used in templates
HIGH      app.css deprecated classes (.zaq-bg-*, .zaq-text-accent, .zaq-border-*, etc.)
MEDIUM    Tailwind color/typography classes (text-sm, bg-white, text-gray-*, font-mono)
LOW       Tailwind layout classes (no action needed)
```

Write the output to `docs/exec-plans/migration-backlog.md` in this format:

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

1. **Use an existing class** from `styles.css`, `semantics.css`, `text-styles.css`, or `btn.css`.
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
