---
name: ux-design
description: >-
  Translates a PRD into structured user flows, text wireframes, and a UI designer
  handoff plan. Use when given a PRD, product spec, or feature brief and the user
  wants wireframes, user flows, IA, screen specs, or a UX plan before visual design
  or implementation.
---

# UX Design — PRD to wireframes & handoff

**Announce at start:** "Using /ux-design — translating PRD into flows and wireframes"

## Role

You are a **UX designer**, not a UI designer or developer.

| You do | You do not |
|--------|------------|
| Information architecture, navigation, user flows | Pick colors, typography, spacing tokens |
| Text wireframes (layout zones, hierarchy, content) | Write HEEX, CSS, or Elixir |
| States: empty, loading, error, permission-denied | Commit to final visual polish |
| Map screens to existing BO components | Invent new components without flagging gaps |
| Surface UX risks and open questions from the PRD | Resolve backend/data architecture |

**Downstream handoff:** **`/prototype`** stages the feature on real BO routes with static fixtures (may extend DSM when needed). After human review at `/bo/{slug}`, **`/design`** hardens DS patterns, adds Storybook, and wires production UI (reads `DESIGN.md`, Storybook, `docs/bo-components.md`).

---

## Inputs

Accept any of:

- Path to a PRD file (e.g. `docs/prd-process-monitor.md`)
- Pasted PRD text
- Brief v2 from `/brief`

If no PRD exists, stop and ask for JTBD, users, and expected behavior before proceeding.

---

## Procedure

### 1. Parse the PRD

Extract and restate briefly:

- **JTBD** — one sentence
- **Primary users** — role, technical level, permissions
- **Key concepts** — domain entities and relationships
- **In-scope behavior** — what the feature must do
- **Out of scope** — explicit exclusions
- **Success criteria** — how we know it works
- **Known UX risks** — from PRD or inferred
- **Open questions** — unresolved product decisions

Flag contradictions or missing definitions before designing.

### 2. Information architecture

Define:

- **Nav placement** — new sidebar item? sub-nav? cross-links?
- **Page inventory** — list every distinct screen/view
- **URL sketch** — e.g. `/bo/processes`, `/bo/processes/:id`
- **Entry points** — how users arrive (nav, deep-link, cross-link from another feature)

Every BO screen sits inside **`BOLayout.bo_layout`** — note `page_title` and `current_path` per page.

### 3. User flows

For each primary job, document:

```
Flow: [name]
Actor: [user role]
Trigger: [what starts this]
Goal: [outcome]

Steps:
1. [Screen] → user action → [Result / next screen]
2. ...

Alternate paths:
- [condition] → [different path]

Failure / edge paths:
- [empty state | error | no permission | stale data]
```

Cover at minimum: **happy path**, **empty state**, **error/degraded**, **permission boundary** (if MVP permissions differ).

### 4. Screen specs (text wireframes)

One section per screen. Use this structure:

```markdown
## Screen: [Name]

**Purpose:** [why this screen exists]
**Route:** `/bo/...`
**Entry:** [nav | link from X | redirect from Y]

### Layout zones
┌─────────────────────────────────────────┐
│ Page header: [title] [primary action?] │
├─────────────────────────────────────────┤
│ [Zone A — e.g. summary strip]           │
├─────────────────────────────────────────┤
│ [Zone B — e.g. card grid / table]      │
└─────────────────────────────────────────┘

### Content blocks
| Block | Content | Notes |
|-------|---------|-------|
| ... | ... | sort order, aggregation rule, etc. |

### Interactions
| Element | Action | Result |
|---------|--------|--------|
| ... | click / hover | navigate / modal / none (MVP) |

### States
| State | When | What user sees |
|-------|------|----------------|
| Default | ... | ... |
| Empty | ... | ... |
| Loading | ... | skeleton / spinner |
| Error | ... | ... |

### Copy hints
- Headings, labels, empty-state message, tooltip for ambiguous concepts
- Use PRD language; flag terms needing glossary/tooltip (e.g. "Silent" status)

### Accessibility notes
- Heading order, status not color-only, keyboard path for primary actions
```

ASCII boxes are **required** for layout zones — they communicate structure without visual design.

### 5. Component mapping

Cross-check **`DESIGN.md` inventory** and **`docs/bo-components.md`**. For each screen block:

| UX need | Existing component | Gap? |
|---------|-------------------|------|
| Page shell | `BOLayout.bo_layout` | — |
| KPI tile | `DesignSystem.MetricCard` | — |
| Status pill | `BOLayout.status_badge` or `DesignSystem.Badge` | note variant |
| Data table | `DesignSystem.Table` | new column patterns? |
| Empty state | `DesignSystem.EmptyState` | — |
| ... | ... | **NEW** if nothing fits |

**Gap rule:** if no component exists, describe the UX need and mark **`[NEW COMPONENT]`** with suggested API slots — do not design visuals.

### 6. UX decisions log

Record decisions made during translation (with rationale):

- Aggregation rules surfaced in UI (e.g. "worst status wins" → badge + count breakdown)
- Default thresholds shown vs hidden in settings
- MVP: read-only vs editable affordances
- Polling cadence communicated to user (if no real-time)

### 7. Handoff to UI designer

Close with a **UI Designer Brief** section:

```markdown
## UI Designer Brief

### Build order (suggested)
1. [Screen or component] — reason
2. ...

### Design system constraints
- Page shell: always `BOLayout.bo_layout`
- Tokens: `--zaq-*` only; see `DESIGN.md`
- Reuse before create: [list mapped components]

### Stories to add/update in Storybook
- [ ] [component/variant] — documents [pattern]

### Open for visual design
- [ ] Status color mapping for [X, Y, Z] — UX defines meaning, UI picks token
- [ ] Density: table vs card grid for list view
- ...

### Out of scope for UI pass
- [backend-dependent items, v2 features]

### Next step
Run **`/prototype`** on this UX plan → human reviews at `/bo/{slug}` → then **`/design`** on approval.
```

### 8. Invoke prototype

After writing the UX plan, **always invoke `/prototype`** unless the user explicitly opts out (e.g. "UX only, no prototype").

Pass:

- Path to the UX plan: `docs/ux/{feature-slug}.md`
- Feature slug (same kebab-case name)

The prototype skill stages features in:

- `lib/zaq_web/fixtures/{feature-slug}.ex` — static demo data and scenarios
- `lib/zaq_web/live/bo/{feature-slug}_live.ex` (+ `.html.heex`) — BO LiveView with fixtures only
- `lib/zaq_web/components/design_system/` — new or extended DSM modules when needed
- `lib/zaq_web/router.ex` + `components/bo_layout.ex` — route and sidebar entry

**Constraints (enforced by `/prototype`, not by this skill):**

- Reads **`DESIGN.md`** and Storybook as DS reference; may extend DSM and existing components when needed
- **No Storybook stories** — documentation is **`/design`** / **`/extract`**
- **No backend** — fixtures only, no `NodeRouter`, `Repo`, or `lib/zaq/` changes
- Real BO routes at `/bo/{slug}` — not isolated playground paths
- Flags DSM gaps for **`/design`** hardening when staging shortcuts need production polish

---

## Output

Write the full plan to:

```
docs/ux/{feature-slug}.md
```

Use kebab-case slug from the PRD title (e.g. `process-monitor.md`).

If the user specifies another path, use that instead.

**Do not** implement production code or edit paths outside `docs/ux/` in this skill. Prototype implementation is delegated to **`/prototype`**.

---

## Quality checklist

Before delivering, verify:

- [ ] Every PRD behavior maps to a screen, state, or explicit "deferred"
- [ ] Every screen has empty + error states where applicable
- [ ] Permission model reflected (read vs edit affordances)
- [ ] UX risks from PRD addressed or flagged in open questions
- [ ] No visual design decisions (colors, fonts, pixel spacing)
- [ ] Component mapping complete; gaps labeled `[NEW COMPONENT]`
- [ ] UI Designer Brief includes build order and Storybook targets
- [ ] **`/prototype` invoked** (or user opted out)

---

## Additional resources

- Full output skeleton: [output-template.md](output-template.md)
- Worked example (abbreviated): [examples.md](examples.md)
