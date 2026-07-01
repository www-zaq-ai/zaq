---
name: iterate
description: >-
  Applies human feedback to an in-progress feature by updating the PRD, then
  re-running ux-design and prototype. Use after the initial pm-senior → ux-design
  → prototype pass when the reviewer sends changes, corrections, or new scope on
  the PRD, UX plan, or staged BO screens.
---

# Iterate — feedback loop for feature discovery

**Announce at start:** "Using /iterate — applying feedback to PRD, UX plan, and prototype"

## Role

You are a **feature iteration orchestrator**. You do not redesign from scratch — you trace human feedback to the right artifact, update upstream docs first, then cascade changes downstream.

| You do | You do not |
|--------|------------|
| Parse and classify human feedback | Re-run pm-senior unless scope is fundamentally new |
| Update the existing PRD with a revision log | Skip PRD when feedback is purely visual |
| Invoke **`/ux-design`** to patch the UX plan | Rewrite the full UX plan when a delta suffices |
| Invoke **`/prototype`** to patch staged screens | Wire backend or edit Storybook |
| Summarize what changed and what to review | Commit or open PRs unless asked |

## Position in the pipeline

```
Initial pass:
  pm-senior → PRD (docs/prd-{slug}.md)
           → /ux-design → UX plan (docs/ux/{slug}.md)
           → /prototype → /bo/{slug}

Feedback loop (this skill):
  human feedback → /iterate → PRD → /ux-design → /prototype → human review
```

Repeat **`/iterate`** until the human approves the staged UI at `/bo/{slug}`.

---

## Inputs

Required:

- **Human feedback** — pasted text, bullet list, or review notes (screens, PRD section, UX concern, copy, flow)
- **Feature slug** — kebab-case (e.g. `process-monitor`)

Optional (infer from slug when omitted):

- PRD path: `docs/prd-{slug}.md`
- UX plan path: `docs/ux/{slug}.md`
- Prototype route: `/bo/{slug}`

If PRD or UX plan is missing, stop and tell the user which upstream skill to run first.

---

## Procedure

### 1. Load current state

Read in parallel:

1. `docs/prd-{slug}.md`
2. `docs/ux/{slug}.md`
3. Prototype files under `lib/zaq_web/` for this slug (LiveView, fixtures, DSM stubs)

Restate briefly: feature name, current PRD status, screens in UX plan, prototype route.

### 2. Parse and classify feedback

For each feedback item, assign:

| Class | Examples | Primary artifact |
|-------|----------|------------------|
| **PRD** | Scope, behavior, permissions, success criteria, concepts, out-of-scope | PRD sections |
| **UX** | Flow, IA, screen layout, states, copy, component mapping | UX plan |
| **Prototype** | Staging bug, wrong component, scenario switcher, fixture data | Prototype code |
| **Mixed** | "Add KPI filter" (scope + screen) | PRD first, then UX, then prototype |

Flag items that:

- Contradict the PRD → resolve in PRD before UX
- Are out of MVP scope → add to PRD "Out of scope" or "Deferred" unless human explicitly promotes them
- Leave open questions → add to PRD open questions; do not guess in UX

Produce a short **Feedback matrix** before editing:

```markdown
| # | Feedback | Class | Target section / screen | Action |
|---|----------|-------|-------------------------|--------|
| 1 | ... | PRD | § Expected Behavior | Update + resolve OQ |
```

### 3. Update the PRD

Edit `docs/prd-{slug}.md` in place.

**Rules:**

- Apply every **PRD** and **Mixed** item that affects product truth
- Do not delete history — append a **Revision log** entry (create the section if missing):

```markdown
## Revision log

| Date | Source | Summary |
|------|--------|---------|
| YYYY-MM-DD | Human review (iterate) | [1-line summary of changes] |
```

- Update **Last updated** in the PRD header
- Move resolved items out of **Open questions** into **Decisions** (add section if needed)
- If feedback rejects prior behavior, strike through old text or replace with clear new wording — one source of truth

**Stop gate:** If feedback is **Prototype-only** (no PRD/UX impact), skip to step 5 and note "PRD unchanged" in the summary.

### 4. Invoke ux-design (update mode)

Read and follow **`/ux-design`**, with these **iterate overrides**:

- **Input:** path to the **updated** PRD + path to the **existing** UX plan
- **Mode:** update — patch affected sections only; do not regenerate the full document
- **Must update when PRD changed:** §1 PRD summary, IA, flows, screen specs, §5 / §5b component mapping, open questions, UI Designer Brief
- **Add or extend** a **Revision log** at the top of the UX plan (mirror PRD date + summary)
- **Do not** opt out of prototype — iterate always continues to step 5 unless the user says "PRD/UX only"

Pass explicitly:

```
/ux-design — UPDATE MODE
PRD: docs/prd-{slug}.md
UX plan: docs/ux/{slug}.md
Changes: [bullet list from feedback matrix affecting UX]
```

### 5. Invoke prototype (update mode)

Read and follow **`/prototype`**, with these **iterate overrides**:

- **Input:** path to the **updated** UX plan + feature slug
- **Mode:** update — change only screens, states, fixtures, or components affected by the UX delta
- Preserve unrelated screens and scenarios
- Update LiveView / Fixtures `@moduledoc` if `[GAP]` or scenarios changed
- Run design system audit (prototype §8) on touched files only

Pass explicitly:

```
/prototype — UPDATE MODE
UX plan: docs/ux/{slug}.md
Slug: {slug}
Scope: [screens / states from feedback matrix]
```

### 6. Verify and summarize

1. Confirm PRD ↔ UX plan ↔ prototype alignment on changed items
2. Run **`/run`** if server status unknown; point reviewer to `/bo/{slug}`
3. Deliver **Iteration summary**:

```markdown
## Iteration summary — {Feature name}

**Feedback applied:** N items (P: x PRD, U: y UX, C: z code)

### PRD (`docs/prd-{slug}.md`)
- [bullets]

### UX plan (`docs/ux/{slug}.md`)
- [bullets]

### Prototype (`/bo/{slug}`)
- [bullets]

### Still open
- [unresolved questions or deferred items]

### Review next
Open `/bo/{slug}` and verify: [specific flows / states from this iteration]
```

---

## Feedback-only shortcuts

| Situation | Action |
|-----------|--------|
| Copy / label tweak on existing screen | UX plan copy hints + prototype text only; PRD unchanged if behavior same |
| Staging bug (wrong badge, broken scenario) | Prototype only; note in iteration summary |
| New screen or removed scope | PRD → full UX delta for that screen → prototype |
| "Start over" / new JTBD | Stop — run **pm-senior** / **`/brief`** again, then ux-design + prototype |

---

## Quality checklist

Before delivering:

- [ ] Every feedback item mapped in the matrix — applied or explicitly deferred
- [ ] PRD revision log entry added when PRD edited
- [ ] UX plan revision log entry added when UX edited
- [ ] **`/ux-design`** invoked when PRD or UX-affecting feedback (update mode)
- [ ] **`/prototype`** invoked when UX or prototype-affecting feedback (update mode)
- [ ] No backend, Storybook, or `lib/zaq/` changes
- [ ] Iteration summary lists what to review at `/bo/{slug}`

---

## Additional resources

- Upstream PRD format: see existing `docs/prd-*.md` (e.g. `docs/prd-process-monitor.md`)
- UX output template: [ux-design/output-template.md](../ux-design/output-template.md)
- Full pipeline after approval: **`/design`** for production DS hardening and data wiring
