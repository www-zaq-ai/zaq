# Design Migration Workflow

**Date:** 2026-06-05  
**Status:** Approved  
**Skill:** `/design-migrate`

---

## Context

ZAQ has a new design token system (`--zaq-*` variables and `.zaq-*` utility classes) defined across `foundations.css`, `semantics.css`, `text-styles.css`, `btn.css`, and `styles.css`. The app's 35 LiveView pages and 17 shared components still use legacy styles: old `app.css` utility classes, hardcoded hex values, legacy token names, and Tailwind text sizing classes.

The goal is to migrate styling to the new system incrementally — layout shell first, then shared components, then pages — without breaking anything in production. Each migration step is staged in Storybook and visually approved before touching app templates.

---

## Invariants (never negotiable)

These rules are embedded verbatim into every agent prompt. The agent cannot override them.

### Class/token precedence

1. **Use an existing class** from `styles.css` ,`semantics.css`, `text-styles.css`, or `btn.css`. Classes in `app.css` are **off-limits** (legacy/deprecated).
2. **Buttons** — always replace with `.zaq-btn-primary` or `.zaq-btn-secondary` from `btn.css`. No new button styles, no daisyUI button classes.
3. **Text** — always map to the closest `.zaq-text-*` class from `text-styles.css`. No Tailwind text sizing (`text-sm`, `text-lg`, `text-[*]`), no inline font vars.
4. **New class needed** → add a new semantic utility class to `styles.css` only. Never add to `app.css`.
5. **No class fits** → use a semantic var inline: `--zaq-surface-color-*`, `--zaq-text-color-*`, or `--zaq-border-color-*`. Never foundation vars (`--zaq-color-blue-*`, `--zaq-color-neutral-*`, `--zaq-color-black-*`).
6. **Tailwind** → as fall back; layout and spacing only, never color or typography.

### Text style mapping

Every text element maps to the closest role in this list — by visual role, not pixel size:

| Role | Class |
|---|---|
| Page/section heading | `.zaq-text-h1` → `.zaq-text-h5` |
| Body copy (large) | `.zaq-text-body-lg` |
| Body copy (default) | `.zaq-text-body` |
| Body copy (small) and table | `.zaq-text-body-sm` |
| Meta / supporting | `.zaq-text-caption` |

When ambiguous between two adjacent scales, prefer the smaller one (e.g. compact UI labels → `.zaq-text-caption` over `.zaq-text-body-sm`). Flag the choice in the diff proposal so the user can override.

**Text decorations are acceptable inline** alongside a `.zaq-text-*` base class — `uppercase`, `lowercase`, `capitalize`, `underline`, `line-through`, `tracking-*`. These are presentational modifiers, not typography scale replacements. The base style must always come from `text-styles.css`; decorations can be added via Tailwind utilities or inline style.
| Code / monospace | `.zaq-text-code` |
| Pre-formatted block | `.zaq-text-pre` |
| Button label | `.zaq-btn-text_label-default` (inside buttons only) |

### Forbidden patterns

- Any class from `app.css` (e.g. `.zaq-bg-ink`, `.zaq-text-accent`, `.zaq-bg-accent-soft`)
- Hardcoded hex, rgb, oklch, or hsl color values in templates
- Foundation vars outside `semantics.css` (e.g. `var(--zaq-color-blue-400)` in a template)
- Tailwind color or typography classes (`text-gray-600`, `bg-white`, `font-mono`, `text-sm`)
- daisyUI component classes in BO templates

---

## Workflow

### Migration order

1. **Layout shell** — `bo_layout.ex` (sidebar, header, shell wrapper)
2. **Shared components** — `core_components.ex`, then component-by-component: modals, cards, inputs, flash, badges
3. **Pages** — grouped by section: Dashboard → AI → Communication → Accounts → System

### The staging loop (per component or section)

```
Input (Figma frame URL or file path)
    ↓
Agent reads target file + design context (if Figma)
    ↓
Agent produces full diff proposal (no files touched yet)
    ↓
You approve / correct / reject individual lines
    ↓
Agent applies approved changes:
    - styles.css (new classes if needed)
    - Storybook story for the component
    ↓
You review visually in Storybook
    ↓
On approval: agent applies same changes to app template
    ↓
style-guard.sh passes
    ↓
PR
```

### Batching

Multiple components can be staged in Storybook before the app-apply step. The skill tracks:
- `staged` — Storybook updated, awaiting visual approval
- `approved` — ready for app template update

Batching is conversation-scoped — the skill tracks staged/approved state within the current session only. There is no persistent state file. When ready to ship a batch, list the approved items and the agent applies them in one pass before the PR.

---

## Skill interface

**File:** `.claude/skills/design-migrate.md`

**Invocation patterns:**

```
/design-migrate                        # prompts for frame or path
/design-migrate <figma-url>            # design-led mode
/design-migrate <file-or-component>    # audit mode
/design-migrate --audit-all            # full codebase sweep → migration backlog
```

### Design-led mode (Figma frame provided)

1. Read Figma frame via `mcp__plugin_figma_figma__get_design_context`
2. Read the target file
3. Produce diff proposal (see format below)
4. Wait for approval
5. Apply to `styles.css` (if new classes) + Storybook story
6. Wait for visual approval in Storybook
7. Apply to app template
8. Run `style-guard.sh`

### Audit mode (no Figma frame)

1. Read the target file
2. Flag every violation of the invariants
3. Propose the closest compliant replacement for each, with reasoning
4. Same approval → Storybook → app → verify → PR loop

### Diff proposal format

```
<file>:<line>  <current-value>          → <proposed-replacement>   (<reason>)

Examples:
bo_layout.ex:142  bg-white              → --zaq-surface-color-raised   (no class for this role)
bo_layout.ex:143  text-[0.82rem]        → .zaq-text-body-sm             (class exists, use it)
bo_layout.ex:198  #03b6d4               → --zaq-border-color-accent     (BLOCKED: hardcoded hex)
bo_layout.ex:201  .zaq-bg-ink           → --zaq-surface-color-dark      (app.css class, off-limits)
bo_layout.ex:220  font-mono text-xs     → .zaq-text-caption             (closest text role)
```

Each line is individually approvable. The agent applies only what you approve.

### Full codebase audit (`--audit-all`)

Sweeps all files under `lib/zaq_web/` and `assets/css/`. Produces a prioritised backlog:

```
CRITICAL  (blocked by style-guard): hardcoded hex, foundation vars in templates
HIGH      (app.css deprecated classes): .zaq-bg-*, .zaq-text-accent, .zaq-border-*
MEDIUM    (Tailwind color/type): text-sm, bg-white, text-gray-*, font-mono
LOW       (Tailwind layout): can stay, not a violation
```

Output written to `docs/exec-plans/migration-backlog.md`.

---

## Verification

After every apply step:

1. `style-guard.sh` — must pass (blocks foundation vars and hardcoded hex)
2. `mix format` — must pass
3. Storybook visual review — human gate, not automated
4. `mix q` — full quality check before PR

---

## CSS file roles (reference)

| File | Purpose | Agent can write? |
|---|---|---|
| `foundations.css` | Raw palette and scale tokens | No |
| `semantics.css` | Semantic color token mappings | No |
| `text-styles.css` | `.zaq-text-*` utility classes | No |
| `btn.css` | Button component tokens and classes | No |
| `styles.css` | New semantic utility classes | Yes |
| `app.css` | Legacy — imports only | No |
