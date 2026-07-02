# Example — Process Monitor (abbreviated)

Source: `docs/prd-process-monitor.md`

---

## IA snapshot

| Page | Route | Nav |
|------|-------|-----|
| Process list | `/bo/processes` | New sidebar: **Processes** |
| Process dashboard | `/bo/processes/:id` | From list row click |
| Workflows (existing) | `/bo/workflows` | Cross-link: show linked Processes |

---

## Flow: Spot a failing process

```
Actor: Growth Manager (read-only BO operator)
Trigger: Opens BO after weekend
Goal: Identify which business process needs attention

1. Processes list → sorted by criticality (worst status first)
2. Row shows aggregated status badge + "2/3 failed" count
3. Click row → Process dashboard
4. Block 1 Sanity Check → failed workflow row → deep-link to Workflow detail
5. Block 2 Business KPIs → scan MetricCards for threshold alerts
```

**Edge:** Process with zero linked workflows → empty state, no dashboard blocks.

---

## Screen: Process list (wireframe excerpt)

```
┌──────────────────────────────────────────────────────────┐
│ Page title: Processes                    [+ New Process?]│  ← edit: creator only
├──────────────────────────────────────────────────────────┤
│ [optional filter/sort — MVP: fixed sort by criticality]  │
├──────────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────────────┐   │
│ │ Process name          Status    Workflows  Updated │   │
│ │ Lead Gen Q3           FAILED    2/3 fail   2h ago  │   │
│ │ Customer Support      OK        4/4 ok     5m ago  │   │
│ └────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

**Empty state copy:** "No processes yet. Create a process and link at least one workflow to see your dashboard."

**UX decision:** Show count breakdown (`2/3 failed`) to address PRD risk "opaque aggregated status."

---

## Screen: Process dashboard (wireframe excerpt)

```
┌──────────────────────────────────────────────────────────┐
│ ← Processes    [Process name]              [Settings?]   │
├──────────────────────────────────────────────────────────┤
│ BLOCK 1 — Sanity Check (auto, no config)                 │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ Workflow name    Status    Last run    [→ Workflow]  │ │
│ │ Onboarding flow  SILENT    26h ago     link          │ │
│ └──────────────────────────────────────────────────────┘ │
│ Tooltip on SILENT: "No run in 24h (configurable)"      │
├──────────────────────────────────────────────────────────┤
│ BLOCK 2 — Business KPIs (from workflow action rules)     │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐                      │
│ │ Metric  │ │ Metric  │ │ Metric  │   ← MetricCard grid  │
│ │ Card    │ │ Card    │ │ Card    │                      │
│ └─────────┘ └─────────┘ └─────────┘                      │
└──────────────────────────────────────────────────────────┘
```

---

## Component mapping (excerpt)

| Need | Component | Gap |
|------|-----------|-----|
| Page shell | `BOLayout.bo_layout` | — |
| Process list | `DesignSystem.Table` | status column + badge variant |
| Aggregated status | `DesignSystem.Badge` | map OK/Failed/Silent/Warning |
| KPI grid | `DesignSystem.MetricCard` | threshold color coding |
| Workflow deep-link | `DesignSystem.Link` | — |
| Empty process | `DesignSystem.EmptyState` | — |
| Sanity row actions | read-only link only (MVP) | no corrective actions |

**[NEW COMPONENT]:** none required for MVP if Table + Badge + MetricCard cover list and dashboard.

---

## UI Designer Brief (excerpt)

**Build order:** (1) Process list + empty state, (2) Process dashboard Block 1 table, (3) Block 2 MetricCard grid, (4) cross-links on Workflows list.

**Open for visual design:** Status badge color token mapping for five sanity statuses; grid density for KPI cards (2 vs 3 columns at `--zaq-layout-page-inset`).
