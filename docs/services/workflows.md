# Workflows Service

DAG-based workflow engine built on [Runic](https://hexdocs.pm/runic). Workflows are defined as a graph of steps (nodes + edges) stored as JSONB, snapshotted at run creation, and executed synchronously by `WorkflowAgent`.

---

## Module Responsibilities

| Module | Responsibility |
|---|---|
| `Zaq.Engine.Workflows` | Public context API — all DB access, run lifecycle, action result tracking |
| `Zaq.Engine.Workflows.Workflow` | Schema: workflow definition (steps JSONB, status, settings) |
| `Zaq.Engine.Workflows.WorkflowRun` | Schema: single run instance (snapshots, status, source_event) |
| `Zaq.Engine.Workflows.ActionResult` | Schema: per-step execution record (crash-safe cursor) |
| `Zaq.Engine.Workflows.Trigger` | Schema: trigger config (type, enabled flag, type-specific config map) |
| `Zaq.Engine.Workflows.WorkflowAgent` | Execution engine — transitions run status, builds DAG, drives Runic |
| `Zaq.Engine.Workflows.ActionWrapper` | Jido.Action wrapper — writes ActionResult rows around every action call |
| `Zaq.Engine.Workflows.DagBuilder` | Builds `Runic.Workflow` struct from the steps JSONB map |
| `Zaq.Engine.Workflows.Triggers.Manual` | Manual trigger — builds `%Zaq.Event{}` and calls `Workflows.create_run/4` |

---

## Execution Flow

```
Trigger.fire/3
  └─> Workflows.create_run/4          # snapshot steps + settings → WorkflowRun (pending)
        └─> Workflows.start_run/2
              └─> WorkflowAgent.execute/2
                    ├─ update_run status: "running"
                    ├─ DagBuilder.build(steps_snapshot, run_id: run.id)
                    │    └─ wraps each action/agent node in ActionWrapper
                    │    └─ builds condition nodes as Runic.Workflow.Step
                    ├─ Runic.Workflow.react_until_satisfied(dag, input)
                    │    └─ ActionWrapper.run/2 (per step)
                    │         ├─ create_action_result  status: "running"
                    │         ├─ mod.run(params, context)
                    │         └─ complete_action_result | fail_action_result
                    └─ finalize/1
                         ├─ any "failed" or "running" row → run = "failed"
                         └─ all "completed" → run = "completed"
```

---

## Steps JSONB Format

The `steps` column on `Workflow` (and `steps_snapshot` on `WorkflowRun`) must follow this shape when the workflow is `active`:

```json
{
  "nodes": [
    {
      "name": "fetch_emails",
      "type": "action",
      "module": "Zaq.Agent.Tools.Email.FetchEmails",
      "params": {},
      "index": 0
    },
    {
      "name": "emails_found",
      "type": "condition",
      "module": "Zaq.Engine.Workflows.Conditions.EmailsFound",
      "params": {},
      "index": 1
    }
  ],
  "edges": [
    {"from": "fetch_emails", "to": "emails_found"}
  ]
}
```

**Node types:**
- `"action"` / `"agent"` — wrapped in `Jido.Runic.ActionNode`. When `run_id` is present, wrapped further by `ActionWrapper`.
- `"condition"` — built as a `Runic.Workflow.Step`. The step passes the fact through if `mod.call(fact)` returns truthy, or raises `"condition_not_met:<name>"` to skip the downstream subgraph.

**Edge fields:**
- `"from"` / `"to"` — node names (strings, matched to node `"name"` field)
- `validate_ports: false` is always set by `DagBuilder` — port validation is disabled system-wide

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
8. Condition nodes receive the full accumulated fact and either pass it through or skip downstream.

The triggering event's payload is preserved through the fact flow as `params.event.payload` in the first action node.

---

## Crash-Safe Cursor (ActionResult)

`ActionWrapper` implements a write-before/update-after pattern:

1. Write `ActionResult` with `status: "running"` before calling the action.
2. Call `mod.run(params, context)`.
3. On `{:ok, result}` → update to `"completed"` with `results` map.
4. On `{:error, reason}` → update to `"failed"` with `errors` map.
5. If the action raises → exception is caught, row marked `"failed"`, `{:error, exception}` returned.

After `react_until_satisfied/2` returns, `WorkflowAgent.finalize/1` queries all `ActionResult` rows for the run. Any row still at `"running"` (process crash mid-action) or `"failed"` causes the run to be marked `"failed"`.

---

## WorkflowRun Status Lifecycle

```
pending → running → completed
                 → failed
```

- `waiting` is defined in the schema for future human-in-the-loop support but not yet driven by the engine.
- A run stuck at `"running"` with no `finished_at` means the executing process crashed. Rehydration is planned (zaq issue follow-up).

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

## Trigger Types

| Type | Config keys required | Implementation |
|---|---|---|
| `manual` | none | `Zaq.Engine.Workflows.Triggers.Manual` |
| `webhook` | none | `Zaq.Engine.Workflows.Triggers.Webhook` |
| `scheduler` | `"cron"` | `Zaq.Engine.Workflows.Triggers.Scheduler` |
| `signal` | `"topic"` | `Zaq.Engine.Workflows.Triggers.Signal` |

`Trigger.module/1` resolves the implementation module from a trigger struct. Disabled triggers (`enabled: false`) are ignored by the runtime — no deletion needed.

---

## Adding a New Action Type

1. Create a module that implements `Jido.Action` (uses `use Jido.Action, name: "...", schema: [...]`).
2. Define `run(params, context)` returning `{:ok, result_map}` or `{:error, reason}`.
3. Register the module in the workflow's `steps` JSONB with `"type": "action"` and the fully-qualified module name in `"module"`.
4. `DagBuilder` will resolve it at runtime via `Module.concat/1` + `Code.ensure_loaded/1` — no code change needed.

**Do not** add the module to any registry or hardcode it anywhere. The module string in JSONB is the only registration.

---

## Adding a New Condition Type

1. Create a module with a `call/1` function that accepts the accumulated fact map and returns a truthy/falsy value.
2. Register it in the workflow steps with `"type": "condition"`.
3. `DagBuilder` wraps it in a `Runic.Workflow.Step` automatically.

There is no behaviour to implement — only `call/1` is required.

---

## Key Invariants (Never Break)

**1. Condition nodes must be `Runic.Workflow.Step`, not `Runic.Workflow.Condition`.**

`Runic.Workflow.Condition` is a `:match` node. It emits `ConditionSatisfied` events consumed only by Rule reactions — it does NOT produce `FactProduced` events that downstream `:execute` (ActionNode) nodes wait for. A condition built with `Runic.condition/2` will silently starve all downstream action nodes. `DagBuilder` intentionally builds conditions as Steps that raise on false. Do not change this.

**2. Steps snapshot is immutable for in-progress runs.**

`WorkflowAgent` reads exclusively from `run.steps_snapshot` and `run.settings_snapshot`. Editing a workflow after a run starts has zero effect on that run. Never pass the live `Workflow` row into `WorkflowAgent`.

**3. `ActionWrapper` wrapper keys must be stripped before delegating.**

`ActionWrapper` removes `[:wrapped_module, :run_id, :step_name, :step_index]` from params before calling `mod.run/2`. The wrapped module must only see its own domain params. Adding new wrapper-internal keys requires updating `@wrapper_keys`.

**4. Module resolution uses `Module.concat/1`, never `String.to_atom/1`.**

`DagBuilder.resolve_module/1` splits the module string on `"."` and calls `Module.concat/1`, then verifies existence with `Code.ensure_loaded/1`. This prevents atom table exhaustion from untrusted JSONB input.

**5. `params` key atomization uses `String.to_existing_atom/1`.**

`atomize_keys/1` in `DagBuilder` uses `String.to_existing_atom/1` inside a `rescue ArgumentError` block. Unknown string keys in `params` silently pass through as strings. Actions should document which param keys they require and whether they expect atoms or strings.

---

## What NOT to Do

- **Do not call `Runic.condition/2`** to build condition nodes. It creates `:match` nodes that do not propagate facts to downstream `:execute` nodes. Use `Runic.Workflow.Step` with a raise on false (already done by `DagBuilder`).
- **Do not read the live `Workflow` row inside `WorkflowAgent`** — only the snapshot fields on `WorkflowRun` are authoritative for a running execution.
- **Do not skip `ActionWrapper`** when `run_id` is present. Calling action modules directly bypasses the crash-safe cursor and leaves no audit trail.
- **Do not use `String.to_atom/1` for module resolution** from untrusted JSONB data. Always use `Module.concat/1` + `Code.ensure_loaded/1`.
- **Do not add new trigger types without implementing the `TriggerBehaviour`** and registering the module in `Trigger.@type_to_module`.
- **Do not check permissions inside `Zaq.Engine.Workflows` functions** — the module doc explicitly states permission checks are the caller's responsibility.
