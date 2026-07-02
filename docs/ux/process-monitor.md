# UX Plan — Process Monitor

**Source PRD:** `docs/prd-process-monitor.md`  
**Date:** 2026-06-30  
**Status:** Draft — pending review  
**Last updated:** 2026-07-01

## Revision log

| Date | Source | Summary |
|------|--------|---------|
| 2026-07-01 | Human review (iterate) | Long linked-workflow picker spec; KPI chart types wired to telemetry components; Sanity Check scroll at scale. |
| 2026-06-30 | UX design | Initial flows and screen specs from PRD. |

---

## 1. PRD summary

| Field | Value |
|-------|-------|
| JTBD | Know whether automated business processes and their objectives are healthy — without digging through logs |
| Primary users | Business operators (Growth Manager, Customer Support Lead); non-technical; understand business metrics, not run internals |
| Permissions | **Read:** all BO operators · **Edit:** process creator only (process settings + KPI definitions) |
| In scope | Process list with aggregated status; process dashboard (Sanity Check + Business KPIs); KPI definition on Process; metric collection on Workflow actions (cross-linked); cross-links Processes ↔ Workflows; 5‑min polling; deep-links to workflows; silent threshold (default 24h, per-process) |
| Out of scope (MVP) | Alerts (email/Mattermost); external KPI sources; corrective actions in dashboard; real-time PubSub |
| Success criteria | Problem identified without visiting Workflows; KPIs configured without help; status reflects anomalies within polling window |

### Key concepts

- **Process:** User-named grouping of Workflows tied to one business objective (e.g. "Lead Generation Q3").
- **Process ↔ Workflow:** Many-to-many; same Workflow can appear in multiple Processes.
- **Metric:** Raw value collected when a workflow step runs and a collection rule matches. Configured on **Workflow actions**; persisted via telemetry (`metric_key`). Not shown on the Process dashboard by itself.
- **KPI:** Business-facing indicator on the Process dashboard. Defined on the **Process**; references one or more metrics via a **formula**; controls display name, time window, alert threshold, and card type.
- **Pipeline:** `Workflow action → metric(s) → KPI formula → Process dashboard card`
- **Aggregated status:** Worst status among linked Workflows drives list badge; show count breakdown (e.g. "2/3 failed").
- **Sanity Check:** ZAQ-internal health per linked Workflow (OK, Failed, Silent, Warning, Unavailable) — not user-configurable KPIs.
- **Silent:** No run within threshold (default 24h); threshold configurable per Process by creator.
- **Warning:** Run stuck in `running` >1h.
- **Type 3:** Collection may trigger a sub-workflow; metric/KPI finalization pending until completion; failure surfaces in Sanity Check and may leave KPI **incomplete** (warning icon on card).

### Known UX risks (from PRD)

| Risk | Mitigation in UX |
|------|------------------|
| "Silent" ambiguous without threshold | Show threshold in UI + tooltip; editable by creator on process settings |
| Opaque aggregated status | Explicit "worst wins" rule + count breakdown on list and dashboard header |
| 5‑min polling feels stale | "Last updated" timestamp at list + dashboard |
| Type 3 incomplete data confuses operators | Warning icon on KPI card + tooltip linking to Sanity Check / source workflow |
| Metrics vs KPIs conflated | Separate labels in copy: "Metrics (collected on workflows)" vs "KPIs (shown here)" |

### Open questions (from PRD + UX)

- [ ] **KPI evaluation timing:** On-read from rollups vs scheduled pre-computation — affects loading state and "as of" copy on cards.
- [ ] **Status severity order:** Confirm ordering for "worst wins" (proposed: Failed → Warning → Silent → Unavailable → OK).
- [ ] **Type 3 KPI workflow contract:** Input/output schema for delegated workflows — affects formula builder affordances.
- [ ] **Metric key namespacing:** Convention when one workflow belongs to multiple Processes — affects metric picker labels.
- [ ] **Workflows BO UI:** No `/bo/workflows` route exists today — confirm build order with Processes shell.
- [ ] **Process create entry:** Can any operator create a Process (becoming creator), or is creation admin-gated?
- [ ] **Deleted workflow in Process:** Unavailable status — show placeholder name + "Workflow removed" or hide row?
- [ ] **Duplicate KPI display names:** Allowed on same Process, or validated unique?

---

## 2. Information architecture

### Navigation

| Item | Location | Route | `page_title` | Notes |
|------|----------|-------|--------------|-------|
| Processes | New sidebar section **Automation** (or top-level after Dashboard) | `/bo/processes` | Processes | List view; primary entry |
| Process dashboard | — | `/bo/processes/:id` | `{Process name}` | Sanity Check + KPI cards |
| Create process | — | `/bo/processes/new` | New process | Name, workflow links, silent threshold |
| Edit process | — | `/bo/processes/:id/edit` | Edit `{Process name}` | Creator only; settings (not KPI formulas) |
| Add KPI | — | `/bo/processes/:id/kpis/new` | Add KPI | Creator only |
| Edit KPI | — | `/bo/processes/:id/kpis/:kpi_id/edit` | Edit KPI | Creator only |
| Workflows | Same section, below Processes | `/bo/workflows` | Workflows | Metric collection on actions; Process membership badges |

**`current_path`:** exact path for list; `/bo/processes` prefix for dashboard, edit, and KPI routes (sidebar highlights Processes).

### Page inventory

| # | Screen | MVP |
|---|--------|-----|
| 1 | Process list | Yes |
| 2 | Process dashboard | Yes |
| 3 | Create / edit process (name, workflow links, silent threshold) | Yes |
| 4 | Add / edit KPI (formula, display, threshold, card type) | Yes — PRD: KPI definition on Process |
| 5 | Workflows index + action editor metric collection | Yes — PRD cross-link; metric UX lives in Workflow UI |
| 6 | Raw metric explorer on Process | No — metrics are builder inputs, not operator-facing |

### Cross-links

| From | To | Trigger |
|------|-----|---------|
| Sidebar | Process list | Nav click |
| Process list row | Process dashboard | Row / name click |
| Process dashboard — Sanity Check row | Workflow detail | Workflow name link |
| Process dashboard — KPI card warning | Sanity Check anchor / workflow | Tooltip link |
| Process dashboard — empty KPIs | Add KPI (creator) or Workflows | CTA |
| Process dashboard — empty workflows | Edit process (creator) | CTA |
| KPI form — metric picker | Workflow action (metric source) | "Defined in Workflow →" link per metric key |
| Workflows list — row | Process dashboard | Process name chip/link |
| Workflow action editor | Linked Processes | Process name links |
| Workflow action editor | Metric keys list | In-place; feeds Process KPI picker |

---

## 3. User flows

### Flow A: Scan fleet health

**Actor:** Any BO operator  
**Trigger:** Opens Processes from sidebar  
**Goal:** Spot which business objectives need attention

```
1. [Process list] → scan aggregated status badges sorted by criticality
2. User clicks row with Failed / Warning → [Process dashboard]
3. [Sanity Check block] → identify failing Workflow(s)
4. Click Workflow name → [Workflow detail] (intervention outside Process Monitor)
```

**Alternates:**
- All OK → user leaves without drilling down (success)
- No processes exist → [Empty state A] → create process

**Edge cases:**
- Polling lag → "Last updated 4 min ago" visible; status may be up to 5 min stale
- Process with zero linked workflows → dashboard shows onboarding empty state per PRD

### Flow B: Create first process

**Actor:** Operator (assumed becomes creator)  
**Trigger:** Empty process list  
**Goal:** Group workflows under a business objective

```
1. [Process list — empty] → CTA "Create process"
2. [Create process] → enter name → select ≥1 Workflow (multi-select) → silent threshold (default 24h)
3. Save → [Process dashboard] with Sanity Check; Block 2 empty until KPIs added
4. Creator prompted: "Add KPIs to track your objective" → [Add KPI] or defer
```

**Alternates:**
- No workflows exist yet → CTA "Create a Workflow first" → `/bo/workflows/new`
- Saves with 0 workflows → inline validation "Link at least one Workflow"

**Failure paths:**
- Save error → inline error on form
- Non-creator on edit routes → permission-denied state

### Flow C: Investigate Silent status

**Actor:** Process creator or reader  
**Trigger:** Silent badge on list or dashboard  
**Goal:** Understand whether inactivity is expected

```
1. [Process dashboard] → Sanity Check shows Silent on Workflow X
2. Hover/focus tooltip → "No run in the last 24h" (or custom threshold)
3. Creator: "Edit process settings" → adjust silent threshold
4. Deep-link to Workflow → verify trigger schedule / volume
```

### Flow D: Define a KPI (creator)

**Actor:** Process creator  
**Trigger:** Empty KPI block or "Add KPI" on dashboard  
**Goal:** Show a business metric on the Process dashboard

```
1. [Add KPI] → display name, card type, time window
2. Metric picker → select metric key(s) emitted by linked workflows (labels show workflow + action)
3. Formula → simple preset (sum, ratio) or complex (Type 3 / KPI workflow output)
4. Counter direction + alert threshold → Save
5. Return to [Process dashboard] → new MetricCard in Block 2
```

**Alternates:**
- No metrics configured on linked workflows → empty picker + CTA "Configure metrics on Workflow actions" → deep-link
- Type 3 formula with pending sub-workflow → card shows value when complete; warning icon when incomplete

**Failure paths:**
- Validation error on formula → inline field errors
- Non-creator hits route → permission-denied

### Flow E: Read Business KPIs

**Actor:** Any BO operator  
**Trigger:** Opens process with configured KPIs  
**Goal:** See objective metrics for selected time window

```
1. [Process dashboard] → Block 2 grid of cards (type per KPI definition)
2. Card shows display name, evaluated value, time window label, optional alert if threshold breached
3. Incomplete Type 3 data → warning icon; tooltip explains + link to Sanity Check
```

**Edge cases:**
- No KPIs defined → empty state "No business KPIs yet" + creator CTA "Add KPI"
- Rollup lag → subtle "Data as of {time}" on card footer

### Flow F: Configure metric collection (Workflow)

**Actor:** Workflow editor (often same as process creator)  
**Trigger:** KPI picker shows no metrics  
**Goal:** Emit telemetry from a workflow action

```
1. [Workflow detail] → action step → "Metric collection" section
2. Choose rule type (1 / 2 / 3), conditions, metric key(s)
3. Save workflow → metric keys appear in Process KPI picker
```

*Detailed Workflow action UX is owned by Workflows feature; Process Monitor only cross-links.*

### Flow G: Creator edits process settings

**Actor:** Process creator  
**Trigger:** Edit from dashboard header  
**Goal:** Add/remove workflow links or change silent threshold

```
1. [Process dashboard] → "Edit process" (creator only)
2. [Edit process] → multi-select workflows, silent threshold — KPIs unchanged here
3. Save → return to dashboard; statuses recalc on next poll
```

**Note:** Removing a workflow may orphan KPI formulas referencing its metrics — show validation warning before save.

---

## 4. Screen specifications

### Screen: Process list

**Purpose:** Fleet-wide view of business objectives and worst-case health  
**Route:** `/bo/processes`  
**Entry:** Sidebar → Processes

#### Layout zones

```
┌──────────────────────────────────────────────────────────────┐
│ Page header: Processes                    [+ Create process] │
│ Subtext: Status reflects worst workflow health · Updated …   │
├──────────────────────────────────────────────────────────────┤
│ [Optional] Summary strip: N processes · X need attention     │
├──────────────────────────────────────────────────────────────┤
│ Zone B — Table (sorted by criticality, then name)            │
│  Name | Status | Breakdown | Workflows | Last activity       │
└──────────────────────────────────────────────────────────────┘
```

#### Content blocks

| Block | Content | Notes |
|-------|---------|-------|
| Header action | Create process | Shown if any operator can create; else role-gated |
| Freshness | "Last updated {time}" | From last Oban poll |
| Table — Name | Process name | Primary link to dashboard |
| Table — Status | Aggregated pill | Worst among linked workflows |
| Table — Breakdown | e.g. "2 failed · 1 silent · 3 OK" | Text or compact chips; not color-only |
| Table — Workflows | Count linked | e.g. "4 workflows" |
| Table — Last activity | Most recent run across linked workflows | Relative time |

#### Interactions

| Element | Action | Result |
|---------|--------|--------|
| Row / name | Click | Navigate to `/bo/processes/:id` |
| Create process | Click | Navigate to `/bo/processes/new` |
| Status pill | Hover/focus | Tooltip: "Worst status among linked workflows" |
| Breakdown | Hover/focus | Expand counts by status type |

#### States

| State | When | User sees |
|-------|------|-----------|
| Default | ≥1 process | Populated table |
| Empty | No processes | EmptyState: "Create a process to monitor your workflows" + CTA |
| Loading | Initial fetch | Table skeleton |
| Error | Fetch failed | Inline error + retry |

#### Copy hints

- Page title: **Processes**
- Empty: "Group workflows by business objective and see health at a glance."
- Breakdown tooltip: "Status uses the most severe workflow state: Failed, then Warning, then Silent."

#### Accessibility notes

- Table headers `scope="col"`; status conveyed by text + icon, not color alone
- Sort order: visually indicate "Sorted by urgency"

---

### Screen: Process dashboard

**Purpose:** Single-process Sanity Check + Business KPIs  
**Route:** `/bo/processes/:id`  
**Entry:** List row; cross-link from Workflow

#### Layout zones

```
┌──────────────────────────────────────────────────────────────┐
│ Breadcrumb: Processes / {Name}                               │
│ Page header: {Process name}   [Edit process] [Add KPI] (cr.) │
│ Aggregated: [STATUS PILL]  Breakdown: 2/5 failed · …         │
│ Last updated {time}                                          │
├──────────────────────────────────────────────────────────────┤
│ Block 1 — Sanity Check                                       │
│  "Automatic checks from ZAQ run data"                        │
│  Table: Workflow | Status | Last run | Details               │
├──────────────────────────────────────────────────────────────┤
│ Block 2 — Business KPIs                                      │
│  "Indicators you defined for this process"                   │
│  Grid of MetricCards / chart cards (per KPI card type)       │
└──────────────────────────────────────────────────────────────┘
```

#### Content blocks — Block 1 (Sanity Check)

| Block | Content | Notes |
|-------|---------|-------|
| Row — Workflow | Name (link) | Deep-link to `/bo/workflows/:id` |
| Row — Status | OK / Failed / Silent / Warning / Unavailable | Per PRD |
| Row — Last run | Timestamp or "Never" | — |
| Row — Details | Short reason | e.g. "Run failed 2h ago", "No run in 36h (threshold 24h)" |

#### Content blocks — Block 2 (Business KPIs)

| Block | Content | Notes |
|-------|---------|-------|
| Card | Display name, evaluated value, window label | **Scalar** card type |
| Chart card | Time series or category breakdown | **Time series** / **Category breakdown** card types — wider grid span (½–full row) |
| Alert | Threshold breach styling | From KPI alert threshold |
| Incomplete | Warning icon + tooltip | Type 3 pending/failed; link to Sanity Check |
| Footer meta | "Data as of {time}" | Rollup read path |
| Creator overflow | Edit / delete KPI | Per-card menu (creator only) |

#### Interactions

| Element | Action | Result |
|---------|--------|--------|
| Workflow name | Click | Workflow detail |
| Edit process | Click | Edit settings (creator) |
| Add KPI | Click | `/bo/processes/:id/kpis/new` |
| KPI warning icon | Click/hover | Tooltip + link to failing workflow in Sanity Check |
| MetricCard | Click | MVP: none (read-only dashboard) |

#### States

| State | When | User sees |
|-------|------|-----------|
| Default | Linked workflows + KPIs | Both blocks populated |
| No workflows | 0 links | Full-page empty: "Link at least one Workflow" + edit CTA (PRD onboarding) |
| Sanity only | No KPIs defined | Block 2 EmptyState + "Add KPI" (creator) |
| Loading | Fetch | Section skeletons |
| Error | Partial failure | Block-level error with retry |
| Unavailable rows | Deleted/disabled workflow | Status Unavailable; row still listed |

#### Copy hints

- **Silent tooltip:** "No workflow run in the past {threshold}. Default: 24 hours."
- **Warning tooltip:** "A run has been in progress for more than 1 hour."
- **Unavailable:** "This workflow was deleted or disabled. It does not affect overall status severity."
- **KPI incomplete:** "Computed with incomplete data. See Sanity Check for workflow status."
- **Block 2 intro:** Distinguish from Block 1 — "These KPIs use metrics collected from your workflows."

#### Accessibility notes

- `h1` process name; `h2` for Sanity Check and Business KPIs
- KPI warning: icon + accessible name "Incomplete data"
- Status table: "{Workflow}, status Failed, last run …"

---

### Screen: Create / Edit process

**Purpose:** Name process, link workflows, set silent threshold  
**Route:** `/bo/processes/new`, `/bo/processes/:id/edit`  
**Entry:** List CTA; dashboard Edit (creator)

#### Layout zones

```
┌──────────────────────────────────────────────────────────────┐
│ Page header: New process | Edit {name}                       │
├──────────────────────────────────────────────────────────────┤
│ Field: Process name (required)                               │
│ Field: Linked workflows (searchable multi-select — see spec below) │
│ Field: Silent threshold (hours, default 24) + helper text    │
├──────────────────────────────────────────────────────────────┤
│ Footer: [Cancel] [Save]                                      │
└──────────────────────────────────────────────────────────────┘
```

#### Linked workflows field (long lists)

Processes may link **20+ workflows**. The control must not render as one flat checkbox column.

| Pattern | Spec |
|---------|------|
| **Control** | Combobox: search input filters a scrollable results panel (`max-height` ~240px) |
| **Selection** | Checkbox per row in results; toggling adds/removes from selection |
| **Selected summary** | Removable **chips** above the field showing linked workflow names |
| **Count** | Helper text: "{n} workflows linked" |
| **Empty search** | "No workflows match …" |
| **Sanity Check (dashboard)** | Full table, one row per linked workflow; `scrollable` + **sticky header**; optional sort by severity (Failed first) when many rows |

#### Interactions

| Element | Action | Result |
|---------|--------|--------|
| Search workflows | Type in filter | Results list narrows; panel stays scrollable |
| Toggle workflow | Checkbox / row click | Add/remove chip; update hidden form values |
| Remove chip | Click × on chip | Unlink workflow |
| Save | Submit | Validate ≥1 workflow → redirect to dashboard |
| Cancel | Click | Back to list or dashboard |

#### States

| State | When | User sees |
|-------|------|-----------|
| Permission denied | Non-creator on edit | EmptyState message, no form |
| Validation | 0 workflows | "Link at least one Workflow before saving" |
| Orphan warning | Removing workflow with KPI refs | Confirm dialog listing affected KPIs |

---

### Screen: Add / Edit KPI

**Purpose:** Define a business KPI for the Process dashboard  
**Route:** `/bo/processes/:id/kpis/new`, `/bo/processes/:id/kpis/:kpi_id/edit`  
**Entry:** Dashboard "Add KPI"; card edit menu (creator)

#### Layout zones

```
┌──────────────────────────────────────────────────────────────┐
│ Breadcrumb: Processes / {Name} / Add KPI                     │
│ Page header: Add KPI | Edit {KPI name}                       │
├──────────────────────────────────────────────────────────────┤
│ Section A — Display                                          │
│  Display name | Card type (scalar / time series / breakdown) │
│  Time window (day / week / month / cumulative)               │
├──────────────────────────────────────────────────────────────┤
│ Section B — Data                                             │
│  Metric picker (keys from linked workflows)                  │
│  Formula builder (simple / complex)                          │
│  Counter direction (increment / decrement → formula hint)    │
├──────────────────────────────────────────────────────────────┤
│ Section C — Alerts                                           │
│  Alert threshold + helper                                    │
├──────────────────────────────────────────────────────────────┤
│ Footer: [Cancel] [Save KPI]                                │
└──────────────────────────────────────────────────────────────┘
```

#### Content blocks

| Block | Content | Notes |
|-------|---------|-------|
| Card type | Picker from telemetry-supported types | Align with `Telemetry.Contracts` payloads |
| Metric picker | List grouped by workflow + action | Empty → link to Workflow metric config |
| Formula | Type 1/2 presets; Type 3 KPI workflow selector | Non-technical presets first |
| Threshold | Numeric + comparison | Drives card alert styling |

#### Interactions

| Element | Action | Result |
|---------|--------|--------|
| Metric row link | Click | Open Workflow action where metric is collected |
| Save KPI | Submit | Validate formula + metrics → dashboard |
| Cancel | Click | Back to dashboard |

#### States

| State | When | User sees |
|-------|------|-----------|
| No metrics available | Linked workflows have no collection rules | EmptyState + Workflow CTA |
| Permission denied | Non-creator | Message + back link |
| Validation | Invalid formula / no metrics selected | Inline errors |

#### Copy hints

- Helper: "Metrics are collected when workflow steps run. KPIs combine them into numbers you track here."
- Type 3 note: "Complex KPIs may update only after a triggered workflow completes."

---

### Screen: Workflows list (enhancement)

**Purpose:** Existing workflows index + Process membership  
**Route:** `/bo/workflows`  
**Entry:** Sidebar

#### Layout zones

```
┌──────────────────────────────────────────────────────────────┐
│ … existing workflows table …                                 │
│  … | Linked processes (chips → /bo/processes/:id)            │
│  … | Metrics (count badge — optional MVP)                    │
└──────────────────────────────────────────────────────────────┘
```

#### States

| State | When | User sees |
|-------|------|-----------|
| No linked processes | Workflow orphan | "Not in any process" |

*Metric collection editor lives on Workflow action screen — out of scope except cross-links.*

---

## 5. Component mapping

| Screen / block | Component | Gap? |
|----------------|-----------|------|
| Page shell | `BOLayout.bo_layout` | — |
| Breadcrumb | `DesignSystem.Breadcrumb` | — |
| Process list table | `DesignSystem.Table` | Breakdown column pattern |
| Aggregated status + breakdown | — | **[NEW COMPONENT]** `ProcessHealthSummary` |
| Sanity Check table | `DesignSystem.Table` + `StatusPill` / `StatusBadge` | Five workflow status variants |
| KPI scalar cards | `DesignSystem.MetricCard` | Incomplete-data warning slot |
| KPI time series | `BOTelemetryComponents.time_series_chart` | `DashboardChart` kind `:time_series`; spans 2 cols in dashboard grid |
| KPI category breakdown | `BOTelemetryComponents.donut_chart` | `DashboardChart` kind `:donut`; spans 2 cols in dashboard grid |
| Empty states | `DesignSystem.EmptyState` | — |
| Process settings form | `DesignSystem` inputs + **WorkflowLinkPicker** `[NEW]` | Searchable scroll list + chips; replaces flat checkbox group |
| KPI form | `DesignSystem` inputs + metric picker | **[NEW COMPONENT]** `MetricKeyPicker` |
| Formula builder (simple) | Preset selects + preview | **[NEW COMPONENT]** `KpiFormulaBuilder` (MVP: presets) |
| Workflows — process chips | `DesignSystem.Badge` / `StatusPill` | Link wrapper |
| Permission denied | `DesignSystem.EmptyState` | — |
| Last updated | Text meta (`zaq-text-body-sm`) | — |

### New components needed

| Name | UX responsibility | Suggested slots/attrs |
|------|-------------------|----------------------|
| **ProcessHealthSummary** `[NEW]` | Aggregated pill + count breakdown + tooltip | `status`, `counts`, `rule: "worst_wins"` |
| **WorkflowHealthStatus** `[NEW]` or extend `StatusPill` | Five sanity statuses + detail text | `status`, `detail`, `threshold_hours` |
| **WorkflowLinkPicker** `[NEW]` | Search, scroll, multi-select workflows with chip summary | `workflows`, `selected_ids`, `on_toggle`, `on_remove`, `filter` |
| **MetricKeyPicker** `[NEW]` | Select metric keys grouped by workflow/action | `metrics`, `selected`, `on_change`, `empty_cta` |
| **KpiFormulaBuilder** `[NEW]` | Preset formulas + Type 3 workflow hook | `metric_keys`, `formula_type`, `value` |
| **MetricCard incomplete state** `[GAP]` | Warning icon + tooltip on existing card | `incomplete`, `incomplete_reason`, `help_link` |

---

## 6. UX decisions log

| Decision | Rationale |
|----------|-----------|
| Metrics on Workflow actions; KPIs on Process | PRD configuration split; avoids showing raw metrics on dashboard |
| KPI CRUD on dedicated routes, not embedded in process edit | Formula forms are heavy; keeps settings form simple |
| Worst-status order: Failed → Warning → Silent → Unavailable → OK | Failures first; Unavailable informational |
| Count breakdown wherever aggregated status appears | PRD risk: opaque aggregation |
| Dashboard empty when 0 workflows linked | PRD: "Link at least one Workflow" before dashboard content |
| Silent threshold on process settings, creator-only | PRD per-process configurability |
| No corrective actions on dashboard (MVP) | PRD; deep-link to Workflow is intervention |
| "Last updated" at list + dashboard | Legible 5‑min polling without implying real-time |
| Type 3 incomplete → KPI warning icon, failure in Sanity Check | PRD dual surfacing; tooltip connects blocks |
| Card types from existing telemetry BO patterns | PRD: scalar + time series + donut for MVP |
| Searchable workflow picker with chips for long lists | PRD scale: 20+ linked workflows without layout blowout |
| Chart KPI cards span wider grid columns | Time series / breakdown need readable chart area |
| Orphan warning when unlinking workflow with KPI refs | Prevents silent broken formulas |

---

## 7. UI Designer Brief

### Build order (suggested)

1. **Status vocabulary** — five sanity statuses + aggregated rule (Storybook variants)
2. **ProcessHealthSummary** `[NEW]` — list + dashboard header
3. **Process list** — table + empty + loading/error
4. **Process dashboard** — Sanity Check table, then KPI card grid with incomplete state
5. **Create/edit process** — settings form + validation
6. **Add/edit KPI** — metric picker + formula presets + card type picker
7. **Workflows list column** — linked process chips (depends on Workflows shell)

### Design system constraints

- Page shell: always `BOLayout.bo_layout`
- Tokens: `--zaq-*` only; see `DESIGN.md`
- Reuse: `Table`, `MetricCard`, `EmptyState`, `StatusPill`/`StatusBadge`, `Breadcrumb`

### Stories to add/update in Storybook

- [ ] `StatusPill` — OK, Failed, Silent, Warning, Unavailable
- [ ] `ProcessHealthSummary` — aggregated + breakdown
- [ ] `MetricCard` — threshold alert + incomplete-data warning
- [ ] `MetricKeyPicker` — grouped list + empty state
- [ ] `Table` — process list with breakdown column
- [ ] `EmptyState` — no processes / no KPIs / no workflows / no metrics

### Open for visual design

- [ ] Severity color mapping for five sanity statuses + aggregated pill
- [ ] List density: table vs card grid
- [ ] Breakdown: inline text vs mini chips
- [x] KPI card types beyond scalar (time series, category breakdown) — mapped to `BOTelemetryComponents`
- [ ] Incomplete-data warning treatment on MetricCard (and chart empty state for Type 3)
- [ ] Automation sidebar section placement + icons

### Out of scope for UI pass

- Workflow action metric collection editor (Workflows feature)
- Real-time refresh (v2 PubSub)
- Email/Mattermost alerts
- Corrective action buttons
- KPI evaluation cache internals

### Next step

Run **`/prototype`** on this UX plan → human review at `/bo/process-monitor` → then **`/design`** on approval.
