# Workflows Service

DAG-based workflow engine built on [Runic](https://hexdocs.pm/runic). Workflows are defined as a graph of steps (nodes + edges) stored as JSONB, validated at save time, snapshotted at run creation, and executed synchronously by `WorkflowRunAgent` from a pre-built DAG. Iteration is an internal engine `map` primitive (Runic `FanOut`/`FanIn`) reached through the `Batch` action — never an authorable node type; workflows may also reference other workflows inline via composition.

---

## Module Responsibilities

| Module | Responsibility |
|---|---|
| `Zaq.Engine.Workflows` | Public context API — all DB access, run lifecycle, step run tracking, DAG preparation (`ensure_prepared_dag/1`, `map_over_limit/1`) |
| `Zaq.Engine.Workflows.Workflow` | Schema: workflow definition (steps JSONB, status, settings). `changeset/2` runs full save-time validation of nodes, edges, conditions, triggers |
| `Zaq.Engine.Workflows.WorkflowRun` | Schema: single run instance (snapshots, status, source_event). Virtual field `prepared_dag` carries the executable DAG in-memory (dropped on DB reload) |
| `Zaq.Engine.Workflows.Step.Run` | Schema: per-step execution record (crash-safe cursor); DB table `workflow_action_results`; statuses: `running`, `paused`, `waiting`, `completed`, `failed`, `failed_fatal`, `skipped` |
| `Zaq.Engine.Workflows.Step.Node` | Embedded schema for DAG nodes (file `steps/node.ex`); validates JSONB at changeset time and enforces the module contract — action/agent modules must resolve and satisfy the `Action` contract; translator modules exporting `enrich/2` (e.g. `Batch`) are exempt |
| `Zaq.Engine.Workflows.Step.Edge` | Embedded schema for DAG edges (file `steps/edge.ex`); validates condition op against `EdgeCondition.ops()` |
| `Zaq.Engine.Workflows.Trigger` | Schema (file `triggers/trigger.ex`): trigger config — `event_name` (string) + `enabled` (boolean); purely event-name-driven |
| `Zaq.Engine.Workflows.WorkflowRunAgent` | Execution-only engine (file `workflow_run_agent.ex`) — runs the pre-built DAG carried on `run.prepared_dag`; never builds one. Returns `{:error, :missing_prepared_dag}` if a run arrives without one |
| `Zaq.Engine.Workflows.StepRunner` | Jido.Action runner — writes `Step.Run` rows around every action call |
| `Zaq.Engine.Workflows.DagBuilder` | Builds the `Runic.Workflow` struct from the steps JSONB map; resolves modules, lowers translator nodes (e.g. `Batch`) onto `map` nodes, wires `FanOut`/`FanIn` for `map` nodes, injects `EdgeStep` and `MapCollect`. No longer re-validates persisted workflows beyond resolution/drift safety |
| `Zaq.Engine.Workflows.Node` | Behaviour for type-specific node modules; optional `enrich/2` (build-time enrichment, e.g. lowering a translator onto another node type) and `validate/1` (save-time validation) callbacks |
| `Zaq.Engine.Workflows.Composition` | Workflow-in-workflow composition: splices `"workflow"`-type nodes inline at run creation (`expand/2`), validates single entry/exit, namespacing, and acyclicity (`validate/2`) |
| `Zaq.Engine.Workflows.Action` | Behaviour + contract every `action`/`agent` node must satisfy; `resolve/1`, `validate/1`, `validate_ref/1`; callbacks `on_success/2`, `on_failure/2`; `use Zaq.Engine.Workflows.Action` provides default implementations |
| `Zaq.Engine.Workflows.EdgeCondition` | Operator vocabulary (`ops/0`) and pure evaluation (`evaluate/4`); used by `Step.Edge` for schema validation and `Steps.EdgeStep` at runtime |
| `Zaq.Engine.Workflows.Steps.EdgeStep` | Infrastructure `Jido.Action` injected by `DagBuilder` on conditional/mapping edges; raises `ConditionNotMet` on false; not wrapped by `StepRunner`, never appears in `Step.Run` rows |
| `Zaq.Engine.Workflows.Steps.MapCollect` | Internal tail step for a `"map"` node; runs after the `FanIn` collects every successful per-item result; wrapped by `StepRunner` under the map node's own name and writes the single aggregate `Step.Run`; recovers per-item failures from the per-fork `Step.Run` rows |
| `Zaq.Engine.Workflows.Conditions.ConditionNotMet` | Exception raised by `Steps.EdgeStep` when a condition evaluates to false; triggers branch pruning |
| `Zaq.Engine.Workflows.Conditions.WaitingForApproval` | Exception struct defined for the HITL approval signal; carries `step_name`, `run_id`, `approval_token`. Currently unused at runtime — `Steps.HumanInTheLoop` returns `{:error, {:waiting_for_human, approval_token}}` instead of raising this exception. Reserved for future use. |
| `Zaq.Engine.Workflows.StepApproval` | Schema: per-step approval record for a suspended run; table `step_approvals`; fields `step_name`, `approval_token`, `message`, `decision`, `approved_by`, `approved_at`; statuses: `pending`, `approved`, `rejected` |
| `Zaq.Engine.Workflows.Steps.HumanInTheLoop` | Jido action that suspends a run for human review; creates a `StepApproval` record and returns `{:error, {:waiting_for_human, approval_token}}` |
| `Zaq.Agent.Tools.Workflow.Batch` | Build-time translator (`@behaviour Zaq.Engine.Workflows.Node`, `enrich/2`) that lowers itself onto a `"map"` node. Not a runtime construct |

> **Removed:** `Iterate`, `PipelineRunner`, the bespoke `Batch` runtime, and the standalone `WorkflowApproval` schema no longer exist. Iteration is the engine `map` primitive; approval is per-step (`StepApproval`).

---

## Execution Flow

DAG preparation is owned by the run module (`Workflows`), not the agent. `ensure_prepared_dag/1` builds the DAG before the agent ever runs; a build failure marks the run `failed` and dispatches `run.failed` **before** the run starts (so a build failure never emits `run.started`). The agent only *runs* a pre-built DAG.

```
Trigger fires → Workflows.create_run/4   # snapshot steps + settings → WorkflowRun (pending)
                                          # Composition.expand/2 splices "workflow" nodes inline
                                          # prepared_dag populated in-memory (best-effort)
  └─> Workflows.start_run/2
        ├─ ensure_prepared_dag/1
        │    ├─ reuse run.prepared_dag if present, else DagBuilder.build(steps_snapshot, run_id: run.id)
        │    └─ [build failure] → update_run "failed" + dispatch "run.failed" → {:error, reason}  (no run.started)
        ├─ dispatch_async {:run_started, run}
        └─> WorkflowRunAgent.execute/2          # requires run.prepared_dag, else {:error, :missing_prepared_dag}
              ├─ update_run status: "running"
              ├─ dispatch "run.started"
              ├─ Runic.Workflow.react_until_satisfied(prepared_dag, input, checkpoint: ...)
              │    └─ StepRunner.run/2 (per step; map forks each write their own Step.Run)
              │         ├─ checkpoint re-reads run; if status == "paused" → throw(:pause_requested)
              │         ├─ if terminal Step.Run exists → return stored result
              │         ├─ insert Step.Run  status: "running"
              │         ├─ mod.run(params, context)
              │         └─ update Step.Run  status: "completed" | "failed"
              ├─ catch :pause_requested → return paused run (no dispatch)
              └─ finalize/2
                   ├─ any Step.Run "waiting"  → run = "waiting" + dispatch "run.waiting"
                   ├─ any Step.Run "failed" or "running" → run = "failed" + dispatch "run.failed"
                   └─ all Step.Run "completed" → run = "completed" + dispatch "run.completed"
```

---

## Steps JSONB Format

The `steps` column on `Workflow` (and `steps_snapshot` on `WorkflowRun`) must follow this shape when the workflow is `active`:

```json
{
  "nodes": [
    {"name": "load_items",  "type": "action", "module": "MyApp.LoadItems",        "params": {}, "index": 0},
    {"name": "notify_team", "type": "action", "module": "Zaq.Agent.Tools.Notify", "params": {}, "index": 1},
    {"name": "skip_notify", "type": "action", "module": "Zaq.Agent.Tools.Noop",   "params": {}, "index": 2}
  ],
  "edges": [
    {"from": "load_items", "to": "notify_team",
     "condition": {"field": "count", "op": "gt", "value": 0},
     "mapping":   {"email_count": "count"}},
    {"from": "load_items", "to": "skip_notify"}
  ]
}
```

**Authorable node types** (`Step.Node.types/0` ⇒ `action`, `agent`, `workflow`):
- `"action"` / `"agent"` — wrapped in `Jido.Runic.ActionNode`. When `run_id` is present, wrapped further by `StepRunner`. The `module` must satisfy the `Action` contract at save time.
- `"workflow"` — references another workflow by `params["workflow_ref"]`. Its steps are spliced inline at run creation by `Composition` (single entry/exit, namespaced node names, acyclicity validated at save). No child run is created.

Iteration is **not** an authorable node type. Authors express it through the `Batch` **action** (`type: "action"`, `module: "Zaq.Agent.Tools.Workflow.Batch"`). A Batch node carries a flat inline `process` pipeline (+ optional `post_process`) and a `delivery` param: `"item"` (one fan-out unit per item) or `"list"` (per chunk of `batch_size`, the default). There is **no** `Iterate` node — delivery mode is the explicit param, not a wrapper. `Batch.enrich/2` lowers it onto the internal `"map"` node at build time; `Batch.validate/1` validates the inline pipeline + delivery at save. The same rule holds for any future orchestration primitive — it ships as an `action` tool that enriches onto an internal node type, so the authoring surface stays `action`/`agent`/`workflow`.

**Internal `"map"` node** (produced only by a translator's `enrich/2`, never authored): the iteration primitive (Runic `FanOut`/`FanIn`). Runs an inline `params["body"]` pipeline once per item of the upstream collection named by `params["over"]`. Each item writes its own per-fork `Step.Run`; the trailing `MapCollect` writes the single aggregate `Step.Run`. A fan-out cap applies: `params["max_items"]` or the global default `Application.get_env(:zaq, Zaq.Engine.Workflows)[:map_max_items]` (defaults to `10_000`). Exceeding it surfaces `{:error, {:map_over_limit, …}}` (read back via `Workflows.map_over_limit/1`). `DagBuilder` still accepts `"map"` in a run's `steps_snapshot` because that is where lowering writes it.

**Edge fields:**
- `"from"` / `"to"` — node names (strings, matched to node `"name"` field).
- `"condition"` — optional map with `"field"`, `"op"`, and optionally `"value"`. Supported ops: `eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `not_empty`, `empty`, `in`. When present, an `EdgeStep` is injected between the two nodes; a false condition raises `ConditionNotMet`, pruning that branch while sibling edges continue.
- `"mapping"` — optional map of `"target_key" => "source_key"` string pairs. The `EdgeStep` renames source keys to target keys in the downstream fact. Source keys in the mapping are consumed (not passed through); all other keys pass through unchanged.

---

## Fact Flow

For **event-driven triggers** (e.g., email received, webhook posted):

1. `NodeRouter.dispatch/1` broadcasts a `%Zaq.Event{}` via PubSub.
2. `Engine.EventRegistry` receives the event and calls `Engine.TriggerNode.fire/2` (`fire(event_name, event)`) for each matching trigger.
3. `TriggerNode` builds the `source_event` (private `build_source_event/2`), extracting the event's `request` payload and packaging it into:
   ```elixir
   assigns: %{
     trigger_type: :event,
     input: %{
       event: %{name, trace_id, payload: event.request, assigns: event.assigns}
     }
   }
   ```
4. `Workflows.create_run/4` snapshots this as the run's `source_event`.
5. `WorkflowRunAgent` extracts `run.source_event.assigns[:input]` (safely handling both atom and string keys from JSONB round-trips) as the initial Runic fact.
6. Each action node receives the accumulated fact map as `params` and returns `{:ok, result_map}`.
7. Runic merges the result map into the running fact for downstream nodes.
8. On edges with a `condition`, an `EdgeStep` evaluates the condition against the upstream fact. A false result raises `ConditionNotMet`, pruning that branch. On edges with a `mapping`, the `EdgeStep` renames keys before the fact reaches the downstream node.

The triggering event's payload is preserved through the fact flow as `params.event.payload` in the first action node.

---

## Crash-Safe Cursor (Step.Run)

`StepRunner` implements a write-before/update-after pattern:

1. Write a `Step.Run` row with `status: "running"` before calling the action.
2. Call `mod.run(params, context)`.
3. On `{:ok, result}` → update to `"completed"` with `results` map.
4. On `{:error, reason}` → update to `"failed"` with `errors` map.
5. If the action raises → exception is caught, row marked `"failed"`, `{:error, exception}` returned.

`Steps.EdgeStep` is NOT wrapped by `StepRunner` — it is infrastructure and never appears in `Step.Run` rows.

After `react_until_satisfied/3` returns, `WorkflowRunAgent.finalize/2` queries all `Step.Run` rows for the run. Any row still at `"running"` (process crash mid-action) or `"failed"` causes the run to be marked `"failed"`.

On resume, `StepRunner` first calls `get_terminal_step_run/2` for the `(run_id, step_name)` pair. If a terminal row exists (`completed`, `failed`, `skipped`, or `waiting`), the stored result is returned immediately without calling the wrapped module. For `completed` rows the stored results are returned as `{:ok, results}`; for `failed` rows as `{:error, errors}`; for `skipped` as `{:error, :condition_not_met}`; for `waiting` as `{:error, :waiting_for_human}`. This makes resume idempotent and prevents duplicate step rows.

---

## WorkflowRun Status Lifecycle

```
pending → running → completed
                 → failed
                 → waiting → running (on approve → resume)
                               → completed
                               → failed (if downstream step fails)
                          → failed (on reject)
                 → paused → running (on resume)
                               → completed
                               → failed
                               → paused
```

- `waiting` means a `HumanInTheLoop` step has suspended execution pending approval. Call `Engine.Api.handle_event(event, :workflow, ctx)` with `action: "run.approve"` or `action: "run.reject"` to proceed.
- A run can also reach `cancelled` (via `Workflows.cancel_run/2`) or `interrupted`. On engine boot, `Zaq.Engine.Workflows.StartupRecovery` finds runs stuck in `"running"`/`"pending"` (node restarted mid-flight) and enqueues one `RunRecoveryWorker` Oban job per run, which marks each run `"interrupted"` via `Workflows.interrupt_run/1`.

---

## Workflow Events

All workflow lifecycle changes are broadcast as a single `:workflow` `NodeRouter` event. The operation is encoded in `event.request.action`.

| Action | Source module | Payload fields |
|---|---|---|
| `"workflow.created"` | `Zaq.Engine.Workflows` | `workflow_id` |
| `"run.started"` | `Zaq.Engine.Workflows.WorkflowRunAgent` | `run_id`, `workflow_id` |
| `"run.completed"` | `Zaq.Engine.Workflows.WorkflowRunAgent` | `run_id`, `workflow_id` |
| `"run.failed"` | `Zaq.Engine.Workflows.WorkflowRunAgent` (runtime) / `Zaq.Engine.Workflows.ensure_prepared_dag/1` (build failure, before `run.started`) | `run_id`, `workflow_id` |
| `"run.waiting"` | `Zaq.Engine.Workflows.WorkflowRunAgent` | `run_id`, `workflow_id` |

`"run.waiting"` is dispatched by `finalize/2` when a `HumanInTheLoop` step has suspended the run. See [Human-in-the-Loop](#human-in-the-loop).

Dispatch goes through `NodeRouter.dispatch/1` (async) to the Channels role, which re-broadcasts over `Zaq.PubSub` via `Zaq.Channels.Api` — engine code never calls `Phoenix.PubSub` directly.

### Subscribing

Register once for `:workflow` and branch on `action`:

```elixir
# In an EventRegistry subscriber or NodeRouter handler:
def handle_event(%Event{name: :workflow} = event, _action, _ctx) do
  case event.request do
    %{action: "run.completed", run_id: id} -> notify_downstream(id)
    %{action: "run.failed",    run_id: id} -> alert_on_call(id)
    _ -> event
  end
end
```

### Key invariant

Dispatch is **fire-and-forget**. A subscriber crash or NodeRouter timeout must never roll back a completed run. All dispatch calls happen after the DB write succeeds and are not wrapped in a transaction.

---

## Tracing a Failed Run

```sql
-- 1. Find the run
SELECT id, status, started_at, finished_at FROM workflow_runs WHERE id = '<run_id>';

-- 2. Find the failing step(s)
SELECT step_name, step_index, status, errors, started_at, finished_at
FROM workflow_action_results
WHERE workflow_run_id = '<run_id>'
ORDER BY step_index ASC;

-- 3. A row with status = 'running' and no finished_at = crash cursor (mid-flight on process death)
-- 4. A row with status = 'failed' contains errors->>'reason' with the failure message
```

---

## Trigger Model

Triggers are purely event-name-driven. A `Trigger` record has two fields:
- `event_name` (string, required) — the event name to match
- `enabled` (boolean, default `true`) — disabled triggers are ignored at runtime without deletion

When `NodeRouter.dispatch/1` broadcasts a `%Zaq.Event{}`, `Engine.EventRegistry` matches the event's `name` against all enabled triggers. For each match, `Engine.TriggerNode` creates and starts runs for every active workflow linked to that trigger via the `trigger_workflows` join table. There are no type-based trigger implementations — matching and dispatch are purely by event name.

### Run identity and permission context

Every run's `source_event` carries the identity and permission context that
`StepRunner` injects into each step's context:

- **actor** — canonical execution identity. `TriggerNode` preserves an existing
  triggering event actor, or derives `actor.person` from a broadcast event whose
  request is `%Incoming{person: ...}` before creating the workflow run. Actorless
  events store `actor: nil` — never a fabricated identity.
- **source_request** — optional original `source_event.request` payload. It may be
  `%Incoming{}`, a plain map, nil, or another request shape; it is not the permission
  identity contract.
- **skip_permissions** — `source_event.assigns.skip_permissions` is `true` only when set
  explicitly at run creation: `CronTriggerWorker` marks its trigger payload with
  `machine: true` (translated by `TriggerNode`), and BO manual runs
  (`WorkflowsLive`/`WorkflowDetailLive`) set it directly with an audit-only `bo` actor
  (BO users have no Person record). A missing actor never implies the bypass.

Steps authorize against this context — e.g. `Zaq.Agent.Tools.Accounts.History` resolves
the person from `ctx[:actor]["person"]["id"]` and honors its `person_id` parameter only
under `skip_permissions: true`.

---

## Adding a New Action Type

1. `use Jido.Action, name: "...", schema: [...], output_schema: [...]` — declare a non-empty input schema and a non-empty `output_schema`.
2. Add `use Zaq.Engine.Workflows.Action` (or `@behaviour Zaq.Engine.Workflows.Action` with manual `on_success/2` and `on_failure/2` implementations). `use` provides overridable defaults for both callbacks.
3. Define `run(params, context)` returning `{:ok, result_map}` or `{:error, reason}`.
4. Register the module in the workflow's `steps` JSONB with `"type": "action"` and the fully-qualified module name in `"module"`.
5. `Step.Node.changeset` enforces the `Action` contract at **save time** (`create_workflow`/`update_workflow` → `Workflow.changeset`), so an invalid module is rejected before the workflow is persisted. `DagBuilder` then resolves the module at build time via `Action.resolve/1` (`Module.concat/1` + `Code.ensure_loaded/1`) — no other registration needed.

**Do not** add the module to any registry or hardcode it anywhere. The module string in JSONB is the only registration. A module that fails the `Action` contract (missing `on_success/2`, `on_failure/2`, `schema/0`, or `output_schema/0`) is rejected at save time. Translator modules that export `enrich/2` (e.g. `Batch`) are deliberately exempt — they are not `Action` modules and are lowered to another node type before execution.

---

## Conditional & Data-Connector Edges — Worked Example

```
A → B → C  condition {gender == "male"}   mapping {person_name ← name}  → D
     B → F  condition {gender == "female"} mapping {first_name  ← name}
```

```json
{
  "nodes": [
    {"name": "A", "type": "action", "module": "..Noop",          "params": {}, "index": 0},
    {"name": "B", "type": "action", "module": "..EmitPerson",    "params": {}, "index": 1},
    {"name": "C", "type": "action", "module": "..RequirePersonName", "params": {}, "index": 2},
    {"name": "D", "type": "action", "module": "..Noop",          "params": {}, "index": 3},
    {"name": "F", "type": "action", "module": "..RequireFirstName",  "params": {}, "index": 4}
  ],
  "edges": [
    {"from": "A", "to": "B"},
    {"from": "B", "to": "C",
     "condition": {"field": "gender", "op": "eq", "value": "male"},
     "mapping":   {"person_name": "name"}},
    {"from": "C", "to": "D"},
    {"from": "B", "to": "F",
     "condition": {"field": "gender", "op": "eq", "value": "female"},
     "mapping":   {"first_name": "name"}}
  ]
}
```

- `B` emits `%{name: "Sam", age: 30, gender: "male"}`.
- `DagBuilder` injects an `EdgeStep` on `B→C` and on `B→F`.
- For `gender = "male"`: `B→C` EdgeStep passes (renames `name` → `person_name`); `B→F` EdgeStep raises `ConditionNotMet` → `F` is pruned, its `ActionResult` records `"skipped"`. Run status = `"completed"`.
- For `gender = "female"`: inverse — `C` and `D` are pruned.
- For `gender = "other"`: both conditions fail; both branches pruned; run still `"completed"`.

---

## Key Invariants (Never Break)

**1. EdgeStep must not use `Runic.condition/2`.**

`Runic.Workflow.Condition` is a `:match` node. It emits `ConditionSatisfied` events consumed only by Rule reactions — it does NOT produce `FactProduced` events that downstream `:execute` (ActionNode) nodes wait for. A guard built with `Runic.condition/2` will silently starve all downstream action nodes. `DagBuilder` injects `EdgeStep` as a `Jido.Runic.ActionNode` (a `:execute` node) that raises on false. Do not change this.

**2. Steps snapshot is immutable for in-progress runs.**

The prepared DAG is built once (by `ensure_prepared_dag/1`) from `run.steps_snapshot`, and `WorkflowRunAgent` reads exclusively from `run.prepared_dag`, `run.steps_snapshot`, and `run.settings_snapshot`. Editing a workflow after a run starts has zero effect on that run. Never pass the live `Workflow` row into `WorkflowRunAgent`.

**3. `StepRunner` wrapper keys must be stripped before delegating.**

`StepRunner` removes `[:wrapped_module, :run_id, :step_name, :step_index, :timeout_ms]` from params before calling `mod.run/2`. It also strips `:__cascade__` and `"__cascade__"` (the result accumulator used for cross-step data flow). The wrapped module must only see its own domain params. Adding new wrapper-internal keys requires updating `@wrapper_keys`.

**4. The HITL signal is a return value, not an exception.**

`Steps.HumanInTheLoop.run/2` returns `{:error, {:waiting_for_human, approval_token}}`. `StepRunner` pattern-matches this in its `case` block, calls `Workflows.wait_step_run/1`, and returns `{:error, :waiting_for_human}`. The `"waiting"` detection is then done in `finalize/2` by inspecting `StepRun` statuses. `WaitingForApproval` is defined as an exception struct but is not raised by any current code path — do not add rescue clauses for it expecting it to carry HITL signals.

**5. Module resolution uses `Module.concat/1`, never `String.to_atom/1`.**

`DagBuilder.resolve_module/1` splits the module string on `"."` and calls `Module.concat/1`, then verifies existence with `Code.ensure_loaded/1`. This prevents atom table exhaustion from untrusted JSONB input.

**6. `params` key atomization uses `String.to_existing_atom/1`.**

`atomize_keys/1` in `DagBuilder` uses `String.to_existing_atom/1` inside a `rescue ArgumentError` block. Unknown string keys in `params` silently pass through as strings. Actions should document which param keys they require and whether they expect atoms or strings.

**7. Lifecycle event dispatch is fire-and-forget.**

`WorkflowRunAgent` and `Workflows.create_workflow/1` dispatch `:workflow` events via `NodeRouter` after each state transition. A dispatch failure must not affect run state — do not wrap dispatch calls in transactions or assert on their return values.

---

## What NOT to Do

- **Do not call `Runic.condition/2`** to build guard logic. It creates `:match` nodes that do not propagate facts to downstream `:execute` nodes. Routing conditions belong on edges via the `"condition"` field — `DagBuilder` injects an `EdgeStep` (`ActionNode`) that raises on false.
- **Do not read the live `Workflow` row inside `WorkflowRunAgent`** — only the snapshot fields and the prepared DAG on `WorkflowRun` are authoritative for a running execution.
- **Do not skip `StepRunner`** when `run_id` is present. Calling action modules directly bypasses the crash-safe cursor and leaves no audit trail.
- **Do not use `String.to_atom/1` for module resolution** from untrusted JSONB data. Always use `Module.concat/1` + `Code.ensure_loaded/1`.
- **Do not introduce type-based trigger dispatch** — triggers are event-name-driven only. New trigger sources should dispatch a `%Zaq.Event{}` with the appropriate `name` via `NodeRouter.dispatch/1`; the existing `EventRegistry` + `TriggerNode` path handles the rest.
- **Do not check permissions inside `Zaq.Engine.Workflows` functions** — the module doc explicitly states permission checks are the caller's responsibility.
- **Do not set `"waiting"` status directly** on a `Step.Run` or `WorkflowRun`. Always go through `HumanInTheLoop.run/2` → `{:error, {:waiting_for_human, token}}` → `StepRunner` case-match → `wait_step_run/1`. Direct status writes bypass the approval token creation and leave the run in an unresumable state.
- **Do not call `approve_step/5` or `reject_step/5` outside `Engine.Api`** — these functions perform state transitions that require the permission boundary enforced by `Engine.Api.handle_event/3`.
- **Do not build a DAG inside `WorkflowRunAgent`** — DAG preparation is owned by the run module (`ensure_prepared_dag/1`). The agent only runs a pre-built `run.prepared_dag`.

---

## Human-in-the-Loop

Include `Steps.HumanInTheLoop` as a step to suspend a workflow at that point and wait for human approval before continuing.

**Suspend flow:**

```
WorkflowRunAgent.execute
  └─> StepRunner wraps HumanInTheLoop
        └─> HumanInTheLoop.run/2
              ├─ generates approval_token (UUID)
              ├─ Workflows.create_approval/1 → StepApproval{status: "pending"}
              └─ returns {:error, {:waiting_for_human, approval_token}}
        └─> StepRunner case-matches {:error, {:waiting_for_human, approval_token}}
              ├─ Workflows.wait_step_run(step_run) → StepRun{status: "waiting"}
              └─ returns {:error, :waiting_for_human}
  └─> finalize/2 detects StepRun with status "waiting"
        └─> Workflows.update_run(run, %{status: "waiting"}) + dispatch "run.waiting"
```

**Approve flow:**

```
Engine.Api.handle_event(event, :workflow, ctx)   # event.request.action == "run.approve"
  └─> Workflows.approve_step(run, approval, decision, approved_by)
        ├─ guard: run.status must be "waiting"   (else {:error, :not_waiting})
        ├─ guard: approval.status must be "pending"   (else {:error, :already_decided})
        ├─ transaction:
        │    ├─ StepApproval → status: "approved", decision, approved_by, approved_at
        │    ├─ StepRun{step_name} → status: "completed", results: %{approved: true, decision: ..., approved_by: ...}
        │    └─ WorkflowRun → status: "paused"
        └─> Workflows.resume_run(run)
              └─> ensure_prepared_dag/1 (rebuilds DAG — virtual prepared_dag dropped on reload)
              └─> WorkflowRunAgent.execute
                    └─> StepRunner finds completed StepRun for HumanInTheLoop step
                          └─ returns cached approval data — downstream steps receive it as params
```

**Reject flow:**

```
Engine.Api.handle_event(event, :workflow, ctx)   # event.request.action == "run.reject"
  └─> Workflows.reject_step(run, approval, reason, approved_by)
        ├─ same guards
        ├─ transaction:
        │    ├─ StepApproval → status: "rejected", approved_by, approved_at
        │    ├─ StepRun{step_name} → status: "failed"
        │    └─ WorkflowRun → status: "failed", finished_at, log_summary
        └─> {:ok, failed_run}   # no resume
```

**Permission model (temporary):** the permission boundary is enforced in `Engine.Api.handle_event/3` for the `"run.approve"` / `"run.reject"` actions (see `lib/zaq/engine/api.ex:356`). Approval is per-step (`StepApproval`), keyed by `step_name` + `approval_token`.

**Idempotency:** `StepRunner` checks for an existing terminal `StepRun` before executing any step. Once `approve_step/5` promotes the HITL `StepRun` to `"completed"`, any subsequent resume skips it and passes the stored `%{approved: true, ...}` map to downstream steps automatically.
