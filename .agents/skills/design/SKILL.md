---
name: design
description: Build or extend ZAQ back-office UI using the --zaq-* design system. Read DESIGN.md first, consult Storybook, then use extract, design-migrate, or replace as appropriate. Human confirmation required before apply steps in each skill.
trigger: when building new BO interfaces, components, or design-system patterns
---

# Design — ZAQ back-office UI

**Announce at start:** "Using /design — reading DESIGN.md"

## Step 1: Read the contract

0. If no interactive reference exists yet, confirm **`/ux-design`** and **`/prototype`** ran — review the staged feature at `/bo/{slug}` before building production UI. **`/prototype`** may extend DSM for staging; this skill owns production-ready patterns, Storybook, and real data wiring.

1. Read **`DESIGN.md`** (tokens, CSS catalog, components, Do's/Don'ts).
2. Check **Storybook** for an existing story matching the UI role (`http://localhost:4000/storybook`).
3. For BO operational rules (BOLayout, flash, icons): skim **`docs/bo-components.md`**.

## Step 2: Pick the skill

| Situation | Skill |
|-----------|-------|
| Inline markup should become a reusable component | **`/extract`** |
| Styling needs `--zaq-*` token migration | **`/design-migrate`** |
| Component exists but LiveViews still duplicate markup | **`/replace`** |
| Run app + Storybook locally | **`/run`** |

**Typical order (human confirmation at each skill gate):**

```
extract → design-migrate → replace
```

- **extract** copies UI into `DesignSystem.*` (source call sites unchanged).
- **design-migrate** tokens on the extracted module and/or target files.
- **replace** wires approved components into LiveViews (human approves replacement table).

Do not skip human validation tables in migrate/replace/extract reports.

## Step 3: Write scope

| Allowed | Forbidden |
|---------|-----------|
| `lib/zaq_web/` markup and styling | `lib/zaq/` business logic |
| `assets/css/styles.css` (per skill rules) | `assets/css/app.css` |
| `storybook/` (extract skill) | daisyUI, legacy `app.css` classes |

Role CSS files (`btn.css`, `form.css`, etc.) are read-only unless the design lead approves a token change.

## Step 4: Verify

Run **`mix format`** on touched files. Run **`mix q`** before opening a PR.

Follow `docs/testing-approach.md#feature-e2e-approval-gate`. Keep the same feature
E2E issue current through production wiring and UI corrections; defer feature E2E
authoring until implementation is complete and final human UX/UI approval is
recorded. The extract/migrate/replace gates and prototype acceptance do not replace
that approval. Continue smaller tests, browser inspection, and required existing
E2E execution; repairs to existing E2E must remain minimal and preserve assertions
and intent, never weakening them to hide regressions.

At finalization, verify the recorded approval covers the completed feature and
hand off the consolidated E2E issue for implementation and validation (without
expanding this skill's allowed write scope). Do not declare the overall feature
complete until required E2E passes. Report the issue ID and any approval blocker.
