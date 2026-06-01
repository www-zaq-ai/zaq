# Semantic Token Migration — Layout Shell

## Context

ZAQ has a three-tier CSS token system: foundations (raw palette) → semantics (role aliases) → ZAQ brand extensions (app.css). The semantic tier (`semantics.css`) defines 9 role-based tokens for surfaces and borders, but they are not yet used anywhere in the BO. Components currently use hardcoded Tailwind utilities (`bg-white`, `border-black/10`) or ZAQ-brand tokens (`--zaq-color-surface`), bypassing the semantic layer entirely.

This migration introduces `zaq-*` utility classes for the semantic tokens and applies them to the BO layout shell (sidebar, header, modals, dropdowns, cards) — establishing the semantic tier as the live, in-use reference for all surface and border color decisions.

---

## Scope

**In scope:** Layout shell components — sidebar background, header, modal panels, dropdown menus, diagnostic cards.

**Out of scope:** Sidebar white-opacity overlays (`bg-white/8`, `border-white/10`) — left as Tailwind utilities for now. The `zaq-*` brand tokens in `app.css` are not touched.

---

## Prerequisite (manual)

`semantics.css` lines 13 and 29 have an unclosed CSS comment on `--color-surface-dark`. This silently disables all border tokens below it. **Fix before implementation begins** by closing both comment lines properly.

---

## Step 1 — Add `zaq-*` utility classes in `app.css`

Add a new block after the existing `zaq-*` utilities (after line ~216):

```css
/* ── Semantic surface utilities ────────────────────────────── */
.zaq-bg-surface-base     { background: var(--color-surface-base); }
.zaq-bg-surface-raised   { background: var(--color-surface-raised); }
.zaq-bg-surface-elevated { background: var(--color-surface-elevated); }
.zaq-bg-surface-accent   { background: var(--color-surface-accent); }
.zaq-bg-surface-dark     { background: var(--color-surface-dark); }

/* ── Semantic border utilities ─────────────────────────────── */
.zaq-border-default { border-color: var(--color-border-default); }
.zaq-border-strong  { border-color: var(--color-border-strong); }
.zaq-border-accent  { border-color: var(--color-border-accent); }
.zaq-border-error   { border-color: var(--color-border-error); }
```

---

## Step 2 — Migrate `bo_layout.ex`

| Element | Current | Replace with |
|---------|---------|--------------|
| Sidebar background (line 239) | `zaq-bg-ink` | `zaq-bg-surface-dark` |
| Header background + border (line 372) | `bg-white border-b border-black/10` | `zaq-bg-surface-raised border-b zaq-border-default` |
| Settings dropdown panel (line 424) | `border border-black/10 bg-white` | `border zaq-border-default zaq-bg-surface-raised` |
| User dropdown panel (line 496) | `border border-black/10 bg-white` | `border zaq-border-default zaq-bg-surface-raised` |
| Diagnostic card (line 799) | `bg-white rounded-xl border border-black/10` | `zaq-bg-surface-raised rounded-xl border zaq-border-default` |
| Feature gate card (line 850) | `bg-white rounded-xl border border-dashed border-black/15` | `zaq-bg-surface-raised rounded-xl border border-dashed zaq-border-default` |

---

## Step 3 — Migrate `bo_modal.ex`

| Element | Current | Replace with |
|---------|---------|--------------|
| Modal panel (line 30) | `border border-black/10 bg-white` | `border zaq-border-default zaq-bg-surface-raised` |
| Form dialog panel (line 105) | `border border-black/10 bg-white` | `border zaq-border-default zaq-bg-surface-raised` |
| Form dialog header divider (line 109) | `border-b border-black/[0.08]` | `border-b zaq-border-default` |
| Form dialog footer (line 125) | `border-t border-black/[0.08] bg-white` | `border-t zaq-border-default zaq-bg-surface-raised` |

---

## Step 4 — Update `storybook/semantic/colors.story.exs`

1. Add `surface/dark` swatch to the Surface section (alongside the existing 4).
2. Extend each swatch to show both the CSS variable name and the corresponding `zaq-*` utility class.

The swatch component gains a `utility` assign:

```elixir
<.swatch name="surface/raised" var="--color-surface-raised" utility="zaq-bg-surface-raised" border />
```

Each swatch renders three lines:
- Color block
- Token name (`surface/raised`)
- CSS variable (`--color-surface-raised`)
- Utility class (`.zaq-bg-surface-raised`)

---

## Verification

1. Run the dev server and visually inspect sidebar, header, modals, and dropdowns in both light and dark mode — surfaces and borders should appear identical to before (no visual regression).
2. Open Storybook → Semantic → Colors: confirm `surface/dark` swatch appears and all swatches show both variable and utility class.
3. Toggle `[data-theme="dark"]` in the browser — semantic tokens should flip automatically via the `semantics.css` dark-mode block.
4. Grep for `bg-white` and `border-black/10` in `bo_layout.ex` and `bo_modal.ex` — should return zero results for the migrated elements.
