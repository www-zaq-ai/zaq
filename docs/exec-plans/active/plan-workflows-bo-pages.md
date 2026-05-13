# Plan: Workflows BO Pages

## Goal
Add a Workflows section to the BO under the **AI** sidebar group with three pages:
1. **Workflows List** — table of workflows with run counts, top-right "Import Workflow" action
2. **Workflow Detail** — single workflow view with metadata, triggers, run history, and "Export Workflow" action
3. **Run Detail** — full log trail for one workflow run (step-by-step status + structured logs)

---

## Constraints & Conventions

- Every page wraps in `<BOLayout.bo_layout>` with `current_path` assigned
- All text: `font-mono`; design tokens via CSS vars (never hardcoded colors)
- Tables: `<.table>`, headers: `<.header>`, buttons: `<.button>`
- Status pills reuse `<BOLayout.status_badge>` pattern (or a new `workflow_status_badge` component following the same shape)
- Icons via `<.icon name="hero-*">` (Heroicons) for inline icons; nav icon via `IconRegistry`
- All BO → Engine calls use `NodeRouter.dispatch/1` with `%Zaq.Event{}` — `NodeRouter.call/4` is **deprecated**; direct `Zaq.Engine.Workflows.*` calls are **forbidden** from `lib/zaq_web/`
- Import/Export are JSON-based (encode/decode the workflow definition); no new DB concepts needed
- No new context functions unless the existing API (`list_workflows/0`, `list_runs/1`, `get_run_trace/1`, `get_workflow!/1`) is insufficient — prefer extending queries over new functions
- `mix precommit` must pass; 90% coverage target on new LiveViews

---

## Existing APIs to reuse

| Need | Existing function |
|---|---|
| List all workflows | `Workflows.list_workflows/0` → extend with run count subquery |
| Get one workflow | `Workflows.get_workflow!/1` |
| List runs for workflow | `Workflows.list_runs/2` |
| Full trace for a run | `Workflows.get_run_trace/1` |
| Create workflow (import) | `Workflows.create_workflow/1` |

**New context helpers needed** (minimal additions to `Zaq.Engine.Workflows`):
- `list_workflows_with_run_counts/0` — single query joining `workflow_runs` count (avoids N+1)
- `export_workflow/1` — serialises a `%Workflow{}` to a portable JSON-safe map (nodes, edges, name, description, settings, triggers)
- `import_workflow/1` — inverse: validates and calls `create_workflow/1`
- `count_runs/1` — returns integer count of runs for a workflow (for pagination)
- `list_runs/2` extended to accept `limit:` and `offset:` opts

---

## Step 1 — Context API additions (`lib/zaq/engine/workflows.ex`)

### 1a. `list_workflows_with_run_counts/0`
```
from w in Workflow,
  left_join: r in WorkflowRun, on: r.workflow_id == w.id,
  group_by: w.id,
  select: {w, count(r.id)},
  order_by: [asc: w.name]
```
Returns `[{%Workflow{}, integer()}]`.

### 1b. `export_workflow/1`
Serialises fields: `name`, `description`, `status`, `settings`, `nodes` (embedded), `edges` (embedded).
Returns a plain `%{}` map safe for `Jason.encode!/1`.

### 1c. `import_workflow/1`
Accepts the export map, strips runtime-only fields (`id`, timestamps), calls `create_workflow/1`.

**Tests**: `test/zaq/engine/workflows_test.exs` — add cases for all three.

---

## Step 2 — Router (`lib/zaq_web/router.ex`)

Add inside the existing authenticated BO scope:
```elixir
live "/bo/workflows",            BO.AI.WorkflowsLive,      :index
live "/bo/workflows/:id",        BO.AI.WorkflowDetailLive,  :show
live "/bo/workflows/:id/runs/:run_id", BO.AI.WorkflowRunLive, :show
```

---

## Step 3 — Sidebar (`lib/zaq_web/components/bo_layout.ex`)

In `nav_sections/2`, add to the `"section-ai"` items list:
```elixir
%{
  href: ~p"/bo/workflows",
  icon: "workflows",           # add to IconRegistry (see Step 4)
  label: "Workflows",
  active: String.starts_with?(current_path, "/bo/workflows")
}
```

Update `ai_section_active?/1`:
```elixir
defp ai_section_active?(current_path) do
  current_path == "/bo/agents" or
    String.starts_with?(current_path, "/bo/workflows")
end
```

---

## Step 4 — Icon (`lib/zaq_web/components/icon_registry.ex`)

Register a `"workflows"` nav icon (SVG inline — use a bolt/circuit-board shape consistent with existing nav icons).

---

## Step 5 — Shared component: `WorkflowComponents`

**New file**: `lib/zaq_web/live/bo/ai/workflow_components.ex`

Provides function components shared across all three LiveViews:

| Component | Purpose |
|---|---|
| `<.workflow_status_badge status={...}>` | Pill for workflow status: `draft` (gray), `active` (green), `archived` (muted) |
| `<.run_status_badge status={...}>` | Pill for run status: `pending` (amber), `running` (blue animate), `completed` (green), `failed` (red) |
| `<.step_log_entry log={...}>` | Single structured log row — level icon + message + timestamp |
| `<.run_duration run={...}>` | Human-readable duration from `started_at`/`finished_at` |

These follow the same `attr` / `~H"""` pattern as `BOTelemetryComponents`.

---

## Step 6 — Workflows List LiveView

**File**: `lib/zaq_web/live/bo/ai/workflows_live.ex`

### Assigns
```
current_path: "/bo/workflows"
workflows: [{%Workflow{}, run_count}]   # from list_workflows_with_run_counts/0
import_modal_open: false
import_error: nil
```

### Layout
```
<BOLayout.bo_layout ...>
  <.header>
    Workflows
    <:actions>
      <.button phx-click="open_import">Import Workflow</.button>
    </:actions>
  </.header>

  <.table rows={@workflows}>
    <:col label="Name">...</:col>
    <:col label="Status"><.workflow_status_badge .../></:col>
    <:col label="Runs">{run_count}</:col>
    <:col label=""><.link navigate={...}>View →</.link></:col>
  </.table>

  <%!-- Import modal via BOModal --%>
</.BOLayout.bo_layout>
```

### Events
- `open_import` / `close_import` — toggle modal
- `import_workflow` — receives uploaded JSON file via `consume_uploaded_entries/3`, dispatches via `NodeRouter.dispatch/1` → `Workflows.import_workflow/1`, redirects on success or sets `import_error`

Import modal uses `allow_upload(:workflow_file, accept: ~w(.json), max_entries: 1)` and renders a `<.live_file_input>` inside `BOModal`.

---

## Step 7 — Workflow Detail LiveView

**File**: `lib/zaq_web/live/bo/ai/workflow_detail_live.ex`

### Assigns
```
current_path: "/bo/workflows/:id"
workflow: %Workflow{}
runs: [%WorkflowRun{}]
page: 1
per_page: 20
runs_total: integer
```

### Layout
Two-section page (no MasterDetail — detail is primary):
```
<.header>
  {workflow.name}
  <:actions>
    <.button phx-click="export">Export Workflow</.button>
  </:actions>
</.header>

<%!-- Metadata card: name, description, status badge, settings --%>
<%!-- Runs table: status, started_at, duration, link to run detail --%>
```

### Events
- `export` — dispatches via `NodeRouter.dispatch/1` → `Workflows.export_workflow/1`, returns JSON as a file download via `push_event("download", %{filename: "...", content: "..."})` with a JS hook on the client
- `paginate` — receives `%{"page" => page}`, updates `page` assign and reloads `runs` slice

Pagination uses `list_runs/2` extended with `opts: [limit: per_page, offset: (page-1)*per_page]`. Add `count_runs/1` context helper returning the total count for rendering page controls.

Pagination UI: prev/next buttons + "Page N of M" label, consistent with `font-mono text-[0.82rem]` style.

---

## Step 8 — Run Detail LiveView

**File**: `lib/zaq_web/live/bo/ai/workflow_run_live.ex`

### Assigns
```
current_path: "/bo/workflows/:id/runs/:run_id"
workflow: %Workflow{}
run: %WorkflowRun{}
trace: %{steps: [...]}   # from get_run_trace/1
```

### Layout
```
<.header>
  Run {short_id(@run.id)}  —  <.run_status_badge status={@run.status}/>
  <:subtitle>Started {format_dt(@run.started_at)} · Duration: <.run_duration run={@run}/></:subtitle>
</.header>

<%!-- Breadcrumb: Workflows → {workflow.name} → Run --%>

<%!-- Steps timeline: ordered list of step cards --%>
<%!-- Each step card: step_name, status badge, duration, logs list --%>
<%!-- Logs: <.step_log_entry> per entry in step_run.logs --%>
<%!-- Errors: if status=failed, render errors map in a red pre-style block --%>
```

### Real-time updates (PubSub)
On mount, subscribe to `"workflow_run:#{run_id}"`. The `WorkflowAgent` must broadcast on this topic when:
- Run status changes (`pending → running → completed/failed`)
- A step run is created, completed, or failed

Handle `handle_info({:run_updated, run}, socket)` and `handle_info({:step_updated, step_run}, socket)` to update assigns in place — no full reload.

`WorkflowAgent` broadcasts via `Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow_run:#{run_id}", msg)` after each `update_run` and `complete_step_run` / `fail_step_run` call.

---

## Step 9 — JS download hook (for export)

**File**: `assets/js/hooks/workflow_export.js`

```js
export const WorkflowExport = {
  mounted() {
    this.handleEvent("download", ({ filename, content }) => {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([content], { type: "application/json" }));
      a.download = filename;
      a.click();
    });
  }
};
```

Register in `app.js` hooks map.

---

## Step 10 — Tests

| File | What to cover |
|---|---|
| `test/zaq/engine/workflows_test.exs` | `list_workflows_with_run_counts/0`, `export_workflow/1`, `import_workflow/1` |
| `test/zaq_web/live/bo/ai/workflows_live_test.exs` | mount renders list; import modal open/close; import success + error |
| `test/zaq_web/live/bo/ai/workflow_detail_live_test.exs` | mount renders workflow + runs; export event fires download push_event |
| `test/zaq_web/live/bo/ai/workflow_run_live_test.exs` | mount renders trace; step statuses + logs rendered; failed step shows errors |

---

## Execution Order (dependency chain)

```
Step 1 (context API) 
  → Step 2 (router) + Step 3 (sidebar) + Step 4 (icon)  [parallel]
    → Step 5 (shared components)
      → Step 6 (list LV) + Step 7 (detail LV) + Step 8 (run LV)  [parallel]
        → Step 9 (JS hook)
          → Step 10 (tests)
```

---

## NodeRouter dispatch convention

`NodeRouter.call/4` is **deprecated** — all new BO → Engine calls use `NodeRouter.dispatch/1` with `%Zaq.Event{}`. Pattern:

```elixir
alias Zaq.{Event, NodeRouter}

event = Event.new(
  %{module: Zaq.Engine.Workflows, function: :list_workflows_with_run_counts, args: []},
  :engine
)

case NodeRouter.dispatch(event).response do
  {:ok, workflows} -> ...
  {:error, reason} -> ...
end
```

The `:engine` role routes to `Zaq.Engine.Supervisor` via `Zaq.Engine.Api`. No direct module calls from `lib/zaq_web/`.

---

## Decisions

1. **Import**: JSON file upload via `allow_upload` + `consume_uploaded_entries` inside `BOModal`.
2. **Run Detail**: Live PubSub — `WorkflowAgent` broadcasts on `"workflow_run:#{run_id}"` on every state transition; Run Detail LiveView subscribes on mount.
3. **Runs list**: Full pagination — `list_runs/2` with `limit`/`offset` opts + `count_runs/1`; 20 per page; prev/next controls on Workflow Detail page.
