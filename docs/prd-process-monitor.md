# PRD — Process Monitor

**Status:** Draft  
**Date:** 2026-06-26  
**Author:** Jana Abiakar  
**Last updated:** 2026-07-01 — long workflow lists, KPI chart types confirmed for MVP

---

## JTBD

When I manage automated business processes in ZAQ, I want a dedicated dashboard to immediately know whether my workflows are running correctly and whether my business objectives are being met — without digging through logs.

---

## Target Users

Business operators (Growth Manager, Customer Support Lead) who have configured ZAQ Workflows. Non-technical profile: understands their business metrics, not the internal run structure.

**MVP Permissions:**
- Read: all BO operators
- Edit: process creator only

---

## Key Concepts

### Process
A freely named entity created by the user, grouping a set of ZAQ Workflows tied to a common business objective (e.g. "Lead Generation Q3", "Customer Support").

### Process ↔ Workflows Relationship
Many-to-many: a Process can contain multiple Workflows, and a Workflow can belong to multiple Processes.

**Scale:** A Process may link **many** workflows (20+). There is no artificial MVP cap on link count. UI must remain usable at scale — searchable picker with scroll, selected summary, and a scrollable Sanity Check table (not a collapsed-only summary).

### Metric
A value **collected** when a **workflow step** runs and a collection rule matches. Metrics are raw telemetry inputs — not necessarily shown on the Process dashboard on their own.

- Configured on a **specific workflow action**
- Persisted via the **telemetry pipeline** (buffer → points → rollups)
- Each metric maps to a **`metric_key`** (e.g. `workflow.{workflow_id}.lead.captured`)

### KPI
A **business-facing indicator** displayed on the Process dashboard. A KPI:

- References one or more **metrics**
- Is evaluated by a **formula** (simple or complex)
- Defines **presentation** (display card type, time window, alert threshold)

```
Workflow action → collection rule(s) → metric(s) → KPI formula → Process dashboard card
```

**Configuration split:**
- **Metrics** — defined on **Workflow** actions (what to collect)
- **KPIs** — defined on **Process** (what to show and how to compute it from metrics)

---

## Expected Behavior

### Process List View

- One process → one aggregated status calculated as: **worst status among linked Workflows**
- Count exposed (e.g. "2/3 failed")
- Sorted by criticality
- Empty state: onboarding message "Link at least one Workflow" before showing the dashboard

### Process Dashboard

Two distinct blocks:

---

#### Block 1 — Sanity Check (operational health)

Calculated automatically from ZAQ execution data. No user configuration required. These are **not** business KPIs — they reflect workflow operational health only.

**Possible statuses per linked Workflow:**

| Status | Condition |
|---|---|
| **OK** | Latest runs completed without error, recent activity |
| **Failed** | Run in error, or a Type 3 triggered sub-workflow failed |
| **Silent** | No run in the past >24h (default threshold, configurable per process) |
| **Warning** | Run in `running` status with no `finished_at` for >1h |
| **Unavailable** | Workflow deleted or disabled (does not block the aggregated calculation) |

**Behavior:**
- Deep-link to the relevant Workflow for any intervention
- No corrective actions available in the dashboard (MVP)
- A failed sub-workflow triggered by a Type 3 collection rule surfaces in Sanity Check as Failed

---

#### Block 2 — Business KPIs (user-defined)

Block 2 has two layers: **metric collection** (Workflow) and **KPI definition** (Process).

##### Block 2a — Metric collection (Workflow configuration)

Configured in the **Workflow** interface on a **specific action**. Emits telemetry points; does not define the dashboard card by itself.

| Type | What gets collected | Formula class |
|---|---|---|
| **Type 1 — Simple condition** | One metric when condition X is true | **Simple formula** over one metric |
| **Type 2 — Multiple condition** | Multiple metrics (X, Y, …) when conditions fire | **Simple formula** over several metrics |
| **Type 3 — Condition + workflow** | One or more metrics; may delegate computation to a **KPI workflow** | **Complex formula** over metrics and/or workflow output |

**Examples:**

| Type | Collection | Example |
|---|---|---|
| Type 1 | If information X exists → emit metric A | Lead captured → `lead.captured` |
| Type 2 | If X and Y exist → emit metrics A, B | Lead captured + valid email → `lead.captured`, `lead.email_valid` |
| Type 3 | If X exists → trigger workflow → emit derived metric | Message received → sentiment workflow → `sentiment.score` |

**Per metric (collection):**
- Source workflow + action step
- Condition(s) that trigger emission
- Metric key / label (for builders)
- Emitted value (typically `1` per match, or numeric payload from step output)

**Type 3 collection behavior:**
- Metric finalization may be **pending** until the triggered workflow completes
- On triggered workflow **failure**: metric not finalized → downstream KPI may be **incomplete**

##### Block 2b — KPI definition (Process configuration)

A KPI binds metrics to what the operator sees on the Process dashboard.

**Formula (required):**
- References one or more metric keys
- **Type 1:** simple aggregation (e.g. `SUM(lead.captured) * direction`)
- **Type 2:** simple aggregation over multiple metrics (e.g. count where both conditions met)
- **Type 3:** complex expression or output of a **KPI workflow** delegated to compute the value

**KPI parameters** (belong to the KPI definition, not to raw metric collection):

| Parameter | Role |
|---|---|
| **Display name** | Label on Process dashboard |
| **Counter direction** | Increment or decrement — applied in the **formula** (e.g. `-1 * SUM(...)`) |
| **Time window** | day / week / month / cumulative since creation — scopes rollup queries when evaluating the KPI |
| **Alert threshold** | Drives card alert styling |
| **Display card type** | User picks from **supported BO card types** already used by telemetry dashboards. **MVP requires all three:** scalar metric card, time series chart, category breakdown chart — reusing `Zaq.Engine.Telemetry.Contracts` payloads (same as Conversations / Knowledge Base metrics). Not bespoke charts. |

**Type 3 KPI behavior:**
- KPI value updates only when formula inputs are **complete** (triggered workflow succeeded and metrics finalized)
- If data is incomplete (workflow failed, still running, or missing rollup):
  - KPI value unchanged or partial per formula rules
  - **Warning icon** on the KPI card indicating computed with incomplete data (tooltip links to Sanity Check / source workflow)
  - Failure still surfaces in **Block 1 — Sanity Check**

---

## Data & Telemetry

**Decision:** Reuse **`Zaq.Engine.Telemetry`** — buffered collection and rollup pre-computation — to avoid performance hits from re-scanning workflow runs.

| Layer | Mechanism |
|---|---|
| **Write path** | Workflow action emits `Telemetry.record/4` per metric key → async buffer → `telemetry_points` |
| **Rollups** | `AggregateRollupsWorker` (10-minute buckets) → `telemetry_rollups` |
| **Read path** | Process dashboard KPIs query rollups scoped by time window, then apply the KPI formula |

**Implications:**
- Each **metric** defines at least one telemetry `metric_key`
- Each **KPI** consumes rollup data via its formula — it does not require a separate raw stream unless the formula demands it
- Telemetry allowlist must be extended for workflow/process metrics (e.g. `workflow.*` or `process.*`)

---

## BO Navigation

Two entries in the main menu with cross-links:

- **Processes** → process list + process dashboard (+ KPI definition)
- **Workflows** → existing interface, with metric collection on actions and indication of which Processes each Workflow belongs to

---

## Status Updates

- MVP: Oban polling every 5 minutes
- v2: real-time PubSub

---

## Out of Scope — MVP (v2)

- Email / Mattermost alerts
- KPIs from external sources (webhook, custom formula, manual input)
- Corrective actions in the Process dashboard
- Real-time updates (PubSub)

---

## Success Criteria

| Criterion | Measurement |
|---|---|
| User identifies a problem without going to Workflows | Ratio `process_intervened` / `workflow_navigated_from_process` |
| KPIs configured without technical help | Completion rate of `kpi_added` without abandonment |
| Status updated automatically | Delay between anomaly and visible status change |

**Baseline to collect before launch:**
- Navigation rate toward the Workflows interface from adjacent pages (4 weeks prior)
- Start logging workflow anomalies now to measure detection delay post-launch

---

## Risks

| Level | Domain | Risk | Decision |
|---|---|---|---|
| Critical | Tech | Very high complexity — Process schema, join table, status calculation, telemetry integration, Oban workers | Phase as strict MVP |
| Critical | UX | "Silent" status without defined threshold → ambiguous signal | Default 24h threshold, configurable, documented in the UI |
| High | Tech | Run stuck in `running` (rehydration not implemented in ZAQ) | Display as distinct Warning status |
| High | Tech | KPI recompute over raw workflow runs does not scale | Mandate telemetry buffer + rollups; KPIs are rollup consumers |
| High | UX | Opaque aggregated status in list view | Explicit rule + visible count breakdown |
| Moderate | UX | Type 3 incomplete data confuses operators | Warning icon on KPI card + Sanity Check failure link |
| Moderate | Data | Corrective action taken outside ZAQ is not measurable | Use `workflow_navigated_from_process` as a proxy |

---

## Open Questions

- **KPI evaluation timing:** On-read from rollups vs scheduled pre-computation per KPI (cache invalidation strategy)
- **Type 3 KPI workflow contract:** Input/output schema for delegated workflows
- **Metric key namespacing:** Convention for `metric_key` when one workflow belongs to multiple Processes

---

## Decisions

| Date | Decision |
|------|----------|
| 2026-07-01 | **Long workflow lists:** No cap on linked workflows per Process; Create/Edit uses searchable combobox with scroll + chip summary; Sanity Check uses scrollable table with sticky header. |
| 2026-07-01 | **KPI chart types (MVP):** Scalar, time series (`:time_series`), and category breakdown (`:donut`) — aligned with existing BO telemetry chart components. |

---

## Revision log

| Date | Source | Summary |
|------|--------|---------|
| 2026-07-01 | Human review (iterate) | Long linked-workflow lists; KPI charts confirmed as MVP (scalar + time series + category breakdown). |
| 2026-06-30 | PRD draft | Metrics vs KPIs split; telemetry storage decision. |
