# Workflows Service

DAG-based workflow engine built on [Runic](https://hexdocs.pm/runic). Workflows are defined as a graph of steps (nodes + edges) stored as JSONB, snapshotted at run creation, and executed synchronously by `WorkflowAgent`.

---

## Module Responsibilities

| Module | Responsibility |
|---|---|
| `Zaq.Engine.Workflows` | Public context API — all DB access, run lifecycle, step run tracking |
| `Zaq.Engine.Workflows.Workflow` | Schema: workflow definition (steps JSONB, status, settings) |
| `Zaq.Engine.Workflows.WorkflowRun` | Schema: single run instance (snapshots, status, source_event) |
| `Zaq.Engine.Workflows.Step.Run` | Schema: per-step execution record (crash-safe cursor); DB table `workflow_action_results`; statuses: `running`, `waiting`, `completed`, `failed`, `skipped` |
| `Zaq.Engine.Workflows.Step.Node` | Embedded schema for DAG nodes; validates JSONB at changeset time |
| `Zaq.Engine.Workflows.Step.Edge` | Embedded schema for DAG edges; validates condition op against `EdgeCondition.ops()` |
| `Zaq.Engine.Workflows.Trigger` | Schema: trigger config — `event_name` (string) + `enabled` (boolean); purely event-name-driven |
| `Zaq.Engine.Workflows.WorkflowAgent` | Execution engine — transitions run status, builds DAG, drives Runic |
| `Zaq.Engine.Workflows.ActionWrapper` | Jido.Action wrapper — writes `Step.Run` rows around every action call |
| `Zaq.Engine.Workflows.DagBuilder` | Builds `Runic.Workflow` struct from the steps JSONB map; calls `Action.validate/1` on every node |
| `Zaq.Engine.Workflows.Action` | Behaviour + contract every `action`/`agent` node must satisfy; exports `validate/1`; callbacks `on_success/2`, `on_failure/2`; `use Zaq.Engine.Workflows.Action` provides default implementations |
| `Zaq.Engine.Workflows.EdgeCondition` | Operator vocabulary (`ops/0`) and pure evaluation (`evaluate/4`); used by `Step.Edge` for schema validation and `Steps.EdgeStep` at runtime |
| `Zaq.Engine.Workflows.Steps.EdgeStep` | Infrastructure `Jido.Action` injected by `DagBuilder` on conditional/mapping edges; raises `ConditionNotMet` on false; not wrapped by `ActionWrapper`, never appears in `Step.Run` rows |
| `Zaq.Engine.Workflows.Conditions.ConditionNotMet` | Exception raised by `Steps.EdgeStep` when a condition evaluates to false; triggers branch pruning |
| `Zaq.Engine.Workflows.Conditions.WaitingForApproval` | Exception struct defined for the HITL approval signal; carries `step_name`, `run_id`, `approval_token`. Currently unused at runtime — `Steps.HumanInTheLoop` returns `{:error, {:waiting_for_human, approval_token}}` instead of raising this exception. Reserved for future use. |
| `Zaq.Engine.Workflows.WorkflowApproval` | Schema: approval record per suspended run step; table `workflow_approvals`; statuses: `pending`, `approved`, `rejected` |
| `Zaq.Engine.Workflows.Steps.HumanInTheLoop` | Jido action that suspends a run for human review; creates a `WorkflowApproval` record and returns `{:error, {:waiting_for_human, approval_token}}` |

---

## Execution Flow

```
Trigger.fire/3
  └─> Workflows.create_run/4          # snapshot steps + settings → WorkflowRun (pending)
        └─> Workflows.start_run/2
              └─> WorkflowAgent.execute/2
                    ├─ update_run status: "running"
                    ├─ dispatch "run.started"
                    ├─ DagBuilder.build(steps_snapshot, run_id: run.id)
                    │    ├─ [failure] → update_run "failed" + dispatch "run.failed"
                    │    └─ wraps each action/agent node in ActionWrapper
                    │    └─ injects EdgeStep on conditional/mapping edges
                    ├─ Runic.Workflow.react_until_satisfied(dag, input, checkpoint: ...)
                    │    └─ ActionWrapper.run/2 (per step)
                    │         ├─ if run.status == "paused" → throw(:pause_requested)
                    │         ├─ if completed Step.Run exists → return stored result
                    │         ├─ insert Step.Run  status: "running"
                    │         ├─ mod.run(params, context)
                    │         └─ update Step.Run  status: "completed" | "failed"
                    ├─ catch :pause_requested → return paused run (no dispatch)
                    └─ finalize/2
                         ├─ any Step.Run "waiting"  → run = "waiting" (dispatch: run.waiting — see HITL)
                         ├─ any Step.Run "failed" or "running" → run = "failed" + dispatch "run.failed"
                         └─ all Step.Run "completed" → run = "completed" + dispatch "run.completed"
```

---

## Steps JSONB Format

The `steps` column on `Workflow` (and `steps_snapshot` on `WorkflowRun`) must follow this shape when the workflow is `active`:

```json
{
  "nodes": [
    {"name": "fetch_emails", "type": "action", "module": "Zaq.Agent.Tools.Email.FetchEmails", "params": {}, "index": 0},
    {"name": "notify_team",  "type": "action", "module": "Zaq.Agent.Tools.Notify",            "params": {}, "index": 1},
    {"name": "skip_notify",  "type": "action", "module": "Zaq.Agent.Tools.Noop",              "params": {}, "index": 2}
  ],
  "edges": [
    {"from": "fetch_emails", "to": "notify_team",
     "condition": {"field": "count", "op": "gt", "value": 0},
     "mapping":   {"email_count": "count"}},
    {"from": "fetch_emails", "to": "skip_notify"}
  ]
}
```

**Node types:**
- `"action"` / `"agent"` — wrapped in `Jido.Runic.ActionNode`. When `run_id` is present, wrapped further by `ActionWrapper`.

**Edge fields:**
- `"from"` / `"to"` — node names (strings, matched to node `"name"` field).
- `"condition"` — optional map with `"field"`, `"op"`, and optionally `"value"`. Supported ops: `eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `not_empty`, `empty`, `in`. When present, an `EdgeStep` is injected between the two nodes; a false condition raises `ConditionNotMet`, pruning that branch while sibling edges continue.
- `"mapping"` — optional map of `"target_key" => "source_key"` string pairs. The `EdgeStep` renames source keys to target keys in the downstream fact. Source keys in the mapping are consumed (not passed through); all other keys pass through unchanged.
- `validate_ports: false` is always set by `DagBuilder` — port validation is disabled system-wide.

---

## Fact Flow

For **event-driven triggers** (e.g., email received, webhook posted):

1. `NodeRouter.dispatch/1` broadcasts a `%Zaq.Event{}` via PubSub.
2. `Engine.EventRegistry` receives the event and calls `TriggerNode.fire(event_name, event)` for each matching trigger.
3. `TriggerNode.build_source_event/2` extracts the event's `request` payload and packages it into:
   ```elixir
   assigns: %{
     trigger_type: :event,
     input: %{
       event: %{name, trace_id, payload: event.request, assigns: event.assigns}
     }
   }
   ```
4. `Workflows.create_run/4` snapshots this as the run's `source_event`.
5. `WorkflowAgent` extracts `run.source_event.assigns[:input]` (safely handling both atom and string keys from JSONB round-trips) as the initial Runic fact.
6. Each action node receives the accumulated fact map as `params` and returns `{:ok, result_map}`.
7. Runic merges the result map into the running fact for downstream nodes.
8. On edges with a `condition`, an `EdgeStep` evaluates the condition against the upstream fact. A false result raises `ConditionNotMet`, pruning that branch. On edges with a `mapping`, the `EdgeStep` renames keys before the fact reaches the downstream node.

The triggering event's payload is preserved through the fact flow as `params.event.payload` in the first action node.

---

## Crash-Safe Cursor (Step.Run)

`ActionWrapper` implements a write-before/update-after pattern:

1. Write a `Step.Run` row with `status: "running"` before calling the action.
2. Call `mod.run(params, context)`.
3. On `{:ok, result}` → update to `"completed"` with `results` map.
4. On `{:error, reason}` → update to `"failed"` with `errors` map.
5. If the action raises → exception is caught, row marked `"failed"`, `{:error, exception}` returned.

`Steps.EdgeStep` is NOT wrapped by `ActionWrapper` — it is infrastructure and never appears in `Step.Run` rows.

After `react_until_satisfied/3` returns, `WorkflowAgent.finalize/2` queries all `Step.Run` rows for the run. Any row still at `"running"` (process crash mid-action) or `"failed"` causes the run to be marked `"failed"`.

On resume, `ActionWrapper` first calls `get_terminal_step_run/2` for the `(run_id, step_name)` pair. If a terminal row exists (`completed`, `failed`, `skipped`, or `waiting`), the stored result is returned immediately without calling the wrapped module. For `completed` rows the stored results are returned as `{:ok, results}`; for `failed` rows as `{:error, errors}`; for `skipped` as `{:error, :condition_not_met}`; for `waiting` as `{:error, :waiting_for_human}`. This makes resume idempotent and prevents duplicate step rows.

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
- A run stuck at `"running"` with no `finished_at` means the executing process crashed. Rehydration is planned (zaq issue follow-up).

---

## Workflow Events

All workflow lifecycle changes are broadcast as a single `:workflow` `NodeRouter` event. The operation is encoded in `event.request.action`.

| Action | Source module | Payload fields |
|---|---|---|
| `"workflow.created"` | `Zaq.Engine.Workflows` | `workflow_id` |
| `"run.started"` | `Zaq.Engine.Workflows.WorkflowAgent` | `run_id`, `workflow_id` |
| `"run.completed"` | `Zaq.Engine.Workflows.WorkflowAgent` | `run_id`, `workflow_id` |
| `"run.failed"` | `Zaq.Engine.Workflows.WorkflowAgent` | `run_id`, `workflow_id` |
| `"run.waiting"` | `Zaq.Engine.Workflows.WorkflowAgent` | `run_id`, `workflow_id`, `step_name`, `approval_token`, `prompt` |

`"run.waiting"` is dispatched by the HITL plan. See [Human-in-the-Loop](#human-in-the-loop).

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
`ActionWrapper` injects into each step's context:

- **actor** — `TriggerNode` copies the triggering event's `actor` (channels set it from
  the message author; `Zaq.Agent.Api` enriches it with the IdentityPlug-resolved
  `person_id`). Actorless events store `actor: nil` — never a fabricated identity.
- **skip_permissions** — `source_event.assigns.skip_permissions` is `true` only when set
  explicitly at run creation: `CronTriggerWorker` marks its trigger payload with
  `machine: true` (translated by `TriggerNode`), and BO manual runs
  (`WorkflowsLive`/`WorkflowDetailLive`) set it directly with an audit-only `bo` actor
  (BO users have no Person record). A missing actor never implies the bypass.

Steps authorize against this context — e.g. `Zaq.Agent.Tools.Accounts.History` resolves
the person from `ctx[:actor]["person_id"]` and honors its `person_id` parameter only
under `skip_permissions: true`.

---

## Adding a New Action Type

1. `use Jido.Action, name: "...", schema: [...], output_schema: [...]` — declare a non-empty input schema and a non-empty `output_schema`.
2. Add `use Zaq.Engine.Workflows.Action` (or `@behaviour Zaq.Engine.Workflows.Action` with manual `on_success/2` and `on_failure/2` implementations). `use` provides overridable defaults for both callbacks.
3. Define `run(params, context)` returning `{:ok, result_map}` or `{:error, reason}`.
4. Register the module in the workflow's `steps` JSONB with `"type": "action"` and the fully-qualified module name in `"module"`.
5. `DagBuilder` will call `Action.validate/1` at build time and resolve the module at runtime via `Module.concat/1` + `Code.ensure_loaded/1` — no other registration needed.

**Do not** add the module to any registry or hardcode it anywhere. The module string in JSONB is the only registration. A module that fails `Action.validate/1` (missing `on_success/2`, `on_failure/2`, `schema/0`, or `output_schema/0`) will prevent the DAG from building.

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

`WorkflowAgent` reads exclusively from `run.steps_snapshot` and `run.settings_snapshot`. Editing a workflow after a run starts has zero effect on that run. Never pass the live `Workflow` row into `WorkflowAgent`.

**3. `ActionWrapper` wrapper keys must be stripped before delegating.**

`ActionWrapper` removes `[:wrapped_module, :run_id, :step_name, :step_index, :timeout_ms]` from params before calling `mod.run/2`. It also strips `:__cascade__` and `"__cascade__"` (the result accumulator used for cross-step data flow). The wrapped module must only see its own domain params. Adding new wrapper-internal keys requires updating `@wrapper_keys`.

**4. The HITL signal is a return value, not an exception.**

`Steps.HumanInTheLoop.run/2` returns `{:error, {:waiting_for_human, approval_token}}`. `ActionWrapper` pattern-matches this in its `case` block, calls `Workflows.wait_step_run/1`, and returns `{:error, :waiting_for_human}`. The `"waiting"` detection is then done in `finalize/2` by inspecting `StepRun` statuses. `WaitingForApproval` is defined as an exception struct but is not raised by any current code path — do not add rescue clauses for it expecting it to carry HITL signals.

**5. Module resolution uses `Module.concat/1`, never `String.to_atom/1`.**

`DagBuilder.resolve_module/1` splits the module string on `"."` and calls `Module.concat/1`, then verifies existence with `Code.ensure_loaded/1`. This prevents atom table exhaustion from untrusted JSONB input.

**6. `params` key atomization uses `String.to_existing_atom/1`.**

`atomize_keys/1` in `DagBuilder` uses `String.to_existing_atom/1` inside a `rescue ArgumentError` block. Unknown string keys in `params` silently pass through as strings. Actions should document which param keys they require and whether they expect atoms or strings.

**7. Lifecycle event dispatch is fire-and-forget.**

`WorkflowAgent` and `Workflows.create_workflow/1` dispatch `:workflow` events via `NodeRouter` after each state transition. A dispatch failure must not affect run state — do not wrap dispatch calls in transactions or assert on their return values.

---

## What NOT to Do

- **Do not call `Runic.condition/2`** to build guard logic. It creates `:match` nodes that do not propagate facts to downstream `:execute` nodes. Routing conditions belong on edges via the `"condition"` field — `DagBuilder` injects an `EdgeStep` (`ActionNode`) that raises on false.
- **Do not read the live `Workflow` row inside `WorkflowAgent`** — only the snapshot fields on `WorkflowRun` are authoritative for a running execution.
- **Do not skip `ActionWrapper`** when `run_id` is present. Calling action modules directly bypasses the crash-safe cursor and leaves no audit trail.
- **Do not use `String.to_atom/1` for module resolution** from untrusted JSONB data. Always use `Module.concat/1` + `Code.ensure_loaded/1`.
- **Do not introduce type-based trigger dispatch** — triggers are event-name-driven only. New trigger sources should dispatch a `%Zaq.Event{}` with the appropriate `name` via `NodeRouter.dispatch/1`; the existing `EventRegistry` + `TriggerNode` path handles the rest.
- **Do not check permissions inside `Zaq.Engine.Workflows` functions** — the module doc explicitly states permission checks are the caller's responsibility.
- **Do not set `"waiting"` status directly** on a `Step.Run` or `WorkflowRun`. Always go through `HumanInTheLoop.run/2` → `{:error, {:waiting_for_human, token}}` → `ActionWrapper` case-match → `wait_step_run/1`. Direct status writes bypass the approval token creation and leave the run in an unresumable state.
- **Do not call `approve_run/5` or `reject_run/5` outside `Engine.Api`** — these functions perform state transitions that require the permission boundary enforced by `Engine.Api.handle_event/3`.

---

## Human-in-the-Loop

Include `Steps.HumanInTheLoop` as a step to suspend a workflow at that point and wait for human approval before continuing.

**Suspend flow:**

```
WorkflowAgent.execute
  └─> ActionWrapper wraps HumanInTheLoop
        └─> HumanInTheLoop.run/2
              ├─ generates approval_token (UUID)
              ├─ Workflows.create_approval/1 → WorkflowApproval{status: "pending"}
              └─ returns {:error, {:waiting_for_human, approval_token}}
        └─> ActionWrapper case-matches {:error, {:waiting_for_human, approval_token}}
              ├─ Workflows.wait_step_run(step_run) → StepRun{status: "waiting"}
              └─ returns {:error, :waiting_for_human}
  └─> finalize/2 detects StepRun with status "waiting"
        └─> Workflows.update_run(run, %{status: "waiting"})
```

**Approve flow:**

```
Engine.Api.handle_event(event, :workflow, ctx)   # event.request.action == "run.approve"
  └─> Workflows.approve_run(run, approval, decision, approved_by)
        ├─ guard: run.status must be "waiting"
        ├─ guard: approval.status must be "pending"
        ├─ transaction:
        │    ├─ WorkflowApproval → status: "approved", decision, approved_by, approved_at
        │    ├─ StepRun{step_name} → status: "completed", results: %{approved: true, decision: ..., approved_by: ...}
        │    └─ WorkflowRun → status: "paused"
        └─> Workflows.resume_run(run)
              └─> WorkflowAgent.execute
                    └─> ActionWrapper finds completed StepRun for HumanInTheLoop step
                          └─ returns cached approval data — downstream steps receive it as params
```

**Reject flow:**

```
Engine.Api.handle_event(event, :workflow, ctx)   # event.request.action == "run.reject"
  └─> Workflows.reject_run(run, approval, reason, approved_by)
        ├─ same guards
        ├─ transaction:
        │    ├─ WorkflowApproval → status: "rejected", approved_by, approved_at
        │    ├─ StepRun{step_name} → status: "failed", errors: %{rejected: true, reason: ...}
        │    └─ WorkflowRun → status: "failed", finished_at
        └─> {:ok, failed_run}   # no resume
```

**Permission model (temporary):** `nil` person_id = BO admin, always allowed. Non-nil `person_id` returns `{:error, :unauthorized}` until `workflow-permissions.md` wires `Permissions.can?/4`.

**Idempotency:** `ActionWrapper` checks for an existing completed `StepRun` before executing any step. Once `approve_run/5` promotes the HITL `StepRun` to `"completed"`, any subsequent resume skips it and passes the stored `%{approved: true, ...}` map to downstream steps automatically.
