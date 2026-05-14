# Workflow Triggers Redesign

## Goal

Redesign the trigger model so that:

- Triggers are standalone entities — created with no workflows attached
- A trigger can be assigned to many workflows (many-to-many via join table)
- A trigger can chain into other triggers (self-referential many-to-many)
- Triggers control how their assigned workflows are executed: serial (with a configurable `on_failure` strategy) or parallel (with a `max_concurrency` cap)
- Manual execution is implicit — every workflow is always runnable from the BO without a trigger record

---

## Infrastructure Audit

### What exists today

| Artifact | Location | State |
|---|---|---|
| `Trigger` schema | `lib/zaq/engine/workflows/trigger.ex` | Has `belongs_to :workflow` (1-to-1); has `type`, `config`, `enabled` |
| `TriggerBehaviour` | `lib/zaq/engine/workflows/trigger_behaviour.ex` | `fire/3` takes a single `Workflow.t()` |
| Trigger implementations | `lib/zaq/engine/workflows/triggers/` | `manual.ex`, `webhook.ex`, `scheduler.ex`, `signal.ex` |
| `Workflows.list_triggers/2` | `lib/zaq/engine/workflows.ex:297` | Queries by `workflow_id` |
| `Workflows.create_trigger/2` | `lib/zaq/engine/workflows.ex` | Requires `workflow_id` |
| Migration | `20260501000005_create_triggers.exs` | `workflow_id` NOT NULL FK |

### What does NOT exist

- `trigger_workflows` join table
- `trigger_chains` self-referential join table
- `execution_mode`, `max_concurrency`, `on_failure` fields on triggers
- A `TriggerExecutor` module to orchestrate multi-workflow dispatch
- Cycle detection for trigger chains

### Breaking changes required

- `triggers.workflow_id` must be dropped (triggers are standalone)
- `TriggerBehaviour.fire/3` signature changes — `workflow` arg removed; execution is now the executor's responsibility
- `Workflows.list_triggers/2` changes — no longer queries by `workflow_id` directly

---

## Final Data Model

```
Trigger
  - id
  - type                :scheduler | :webhook | :signal | :manual
  - config              map (type-specific keys)
  - enabled             boolean
  - execution_mode      :serial | :parallel
  - max_concurrency     integer | nil  (parallel only; nil = unlimited)
  - on_failure          :stop | :continue  (serial only)
  ──< trigger_workflows(trigger_id, workflow_id, position) >── Workflow
  ──< trigger_chains(trigger_id, downstream_trigger_id) >───── Trigger (self-ref)
```

**Execution semantics:**
- **Parallel**: all workflows dispatched concurrently up to `max_concurrency`; all run to completion regardless of failures
- **Serial**: workflows run in `position` order; `on_failure: :stop` halts on first failure; `on_failure: :continue` runs all regardless
- **Chained triggers**: after own workflows complete, all downstream triggers are always fired (continue on failure)
- **Manual**: BO calls `Manual.fire/3` directly against a `Workflow` struct — no trigger DB row required

---

## Step 1 — Database Migration

**Functional specifications:**

- New migration drops `workflow_id` from `triggers` and removes its indices
- Adds `execution_mode string NOT NULL DEFAULT 'parallel'`
- Adds `max_concurrency integer NULL`
- Adds `on_failure string NOT NULL DEFAULT 'continue'`
- Creates `trigger_workflows` table: `(id, trigger_id FK, workflow_id FK, position integer NOT NULL DEFAULT 0)`
- Creates `trigger_chains` table: `(trigger_id FK, downstream_trigger_id FK)` — composite PK
- Indices: `trigger_workflows(trigger_id)`, `trigger_workflows(workflow_id)`, `trigger_chains(trigger_id)`, unique on `trigger_chains(trigger_id, downstream_trigger_id)`

**Files to add/edit:**
- `priv/repo/migrations/<timestamp>_redesign_triggers.exs` — new migration

**Tests to add before implementation:**
- None at the migration layer — schema tests are the integration test

**Branches/paths validated:**
- Migration runs forward cleanly on empty triggers table
- Rollback drops both join tables and restores `workflow_id` column

**Mocking plan:** None

**Documentation to update:** None at this step

---

## Step 2 — Trigger Schema + Changeset

**Functional specifications:**

- Remove `belongs_to :workflow` and `workflow_id` field
- Add `execution_mode` as `Ecto.Enum` values `[:serial, :parallel]`, default `:parallel`
- Add `max_concurrency` integer field, nullable
- Add `on_failure` as `Ecto.Enum` values `[:stop, :continue]`, default `:continue`
- Add `many_to_many :workflows` via `trigger_workflows` join table
- Add `many_to_many :downstream_triggers` via `trigger_chains`, join keys `trigger_id` / `downstream_trigger_id`
- Update `changeset/2`:
  - Remove `workflow_id` from cast/validate
  - Cast `execution_mode`, `max_concurrency`, `on_failure`
  - Validate `max_concurrency` is positive integer when present
  - `validate_trigger_config/1` — keep existing cron/topic key validation
- Add `assign_workflows_changeset/2` for updating the `trigger_workflows` association
- Update `Trigger.types/0` — keep `manual` in the enum (used for explicit manual triggers if desired); implicit manual is handled separately

**Files to edit:**
- `lib/zaq/engine/workflows/trigger.ex`

**Tests to add before implementation (`test/zaq/engine/workflows/trigger_test.exs`):**

```
- changeset valid with no workflows
- changeset rejects unknown execution_mode
- changeset rejects negative max_concurrency
- changeset requires cron for scheduler type
- changeset requires topic for signal type
- changeset valid for parallel with max_concurrency nil
- changeset valid for serial with on_failure :stop / :continue
```

**Branches/paths validated:**
- All four trigger types still pass changeset
- Parallel trigger without max_concurrency is valid
- Serial trigger without on_failure defaults to :continue

**Mocking plan:** None

**Documentation to update:**
- `@moduledoc` in `trigger.ex` — update type descriptions and new fields

---

## Step 3 — Workflows Context API Update

**Functional specifications:**

- `list_triggers/1` — remove `workflow_id` parameter; list all triggers (optionally preload `:workflows` and `:downstream_triggers`)
- `list_triggers_for_workflow/2` — new function: returns triggers assigned to a given `workflow_id` (queries via join table)
- `create_trigger/2` — remove `workflow_id` requirement; accepts `execution_mode`, `max_concurrency`, `on_failure`
- `assign_workflow_to_trigger/3` — new: inserts a `trigger_workflows` row with position; idempotent
- `remove_workflow_from_trigger/3` — new: deletes a `trigger_workflows` row
- `chain_trigger/3` — new: inserts a `trigger_chains` row; validates no cycle is introduced
- `unchain_trigger/3` — new: deletes a `trigger_chains` row
- `detect_trigger_cycle?/2` — private: BFS/DFS over `trigger_chains` to detect cycles before insertion
- `delete_trigger/2` — new: deletes a trigger (cascades via FK to join tables)
- All new public functions accept `opts \\ []` as last param

**Files to edit:**
- `lib/zaq/engine/workflows.ex`

**Tests to add before implementation (`test/zaq/engine/workflows_test.exs`):**

```
- list_triggers returns all triggers (not scoped by workflow)
- list_triggers_for_workflow returns only assigned triggers
- create_trigger succeeds with no workflows
- assign_workflow_to_trigger inserts join row with position
- assign_workflow_to_trigger is idempotent
- remove_workflow_from_trigger deletes join row
- chain_trigger inserts downstream chain
- chain_trigger rejects direct cycle (A→A)
- chain_trigger rejects indirect cycle (A→B→A)
- unchain_trigger removes chain row
- delete_trigger cascades to join tables
```

**Branches/paths validated:**
- Cycle detection: direct, indirect (2-hop), and no-cycle paths
- Position ordering is preserved in list_triggers_for_workflow

**Mocking plan:** None

**Documentation to update:**
- `@moduledoc` in `workflows.ex` — document new CRUD functions

---

## Step 4 — TriggerBehaviour + TriggerExecutor

**Functional specifications:**

`TriggerBehaviour` — update signature:
- `fire/2` becomes `fire(trigger, input)` — the behaviour no longer takes a single `Workflow`; the executor handles workflow dispatch
- `on_complete/2` stays as-is (called per `WorkflowRun`)

`TriggerExecutor` — new module (`lib/zaq/engine/workflows/trigger_executor.ex`):
- `execute(trigger, input, opts \\ [])` — public entry point
  1. Preloads `trigger.workflows` (ordered by position) and `trigger.downstream_triggers`
  2. Dispatches workflows per `trigger.execution_mode`:
     - `:parallel` → `Task.async_stream` capped at `max_concurrency` (or `:infinity`); collects results; all run regardless of failures
     - `:serial` → reduce over workflows; on `{:error, _}` check `on_failure`; `:stop` halts; `:continue` proceeds
  3. For each workflow: calls `trigger_module.fire(trigger, input)` then `Workflows.start_run(run)`
  4. After own workflows: fires all `downstream_triggers` via `execute/3` (always, regardless of failures)
  5. Returns `{:ok, results}` where results is a list of `{workflow_id, {:ok | :error, run_or_reason}}`

Update existing trigger implementations to remove the `workflow` argument from `fire/3` → `fire/2`:
- `Triggers.Manual` — `fire(trigger, input)` or `fire(workflow, input)` for the implicit BO case (see Step 5)
- `Triggers.Webhook`, `Triggers.Scheduler`, `Triggers.Signal` — update to `fire(trigger, input)`

Each trigger's `fire/2` now only creates the `%Zaq.Event{}` — it does NOT call `create_run`. `create_run` is called per-workflow inside `TriggerExecutor`.

**Files to add/edit:**
- `lib/zaq/engine/workflows/trigger_behaviour.ex` — update callback spec
- `lib/zaq/engine/workflows/trigger_executor.ex` — new module
- `lib/zaq/engine/workflows/triggers/manual.ex`
- `lib/zaq/engine/workflows/triggers/webhook.ex`
- `lib/zaq/engine/workflows/triggers/scheduler.ex`
- `lib/zaq/engine/workflows/triggers/signal.ex`

**Tests to add before implementation (`test/zaq/engine/workflows/trigger_executor_test.exs`):**

```
- execute parallel: all workflows dispatched; failures in one don't block others
- execute parallel: max_concurrency respected (Task.async_stream cap)
- execute serial: stop on first failure when on_failure :stop
- execute serial: continue after failure when on_failure :continue
- execute serial: all succeed → all runs returned
- execute fires downstream triggers after own workflows complete
- execute downstream triggers fire even when own workflows failed
- execute returns results list with {workflow_id, outcome} tuples
```

**Branches/paths validated:**
- Parallel max_concurrency nil (unlimited)
- Serial with empty workflow list
- Downstream trigger chain depth > 1

**Mocking plan:** None — use real DB rows with in-process test workflow agent

**Documentation to update:**
- `@moduledoc` in `trigger_executor.ex`
- `@moduledoc` in `trigger_behaviour.ex`
- `docs/services/workflows.md` — update Execution Flow diagram and Trigger Types table

---

## Step 5 — Implicit Manual Execution

**Functional specifications:**

- `Triggers.Manual` exposes a second entry point `fire_for_workflow(workflow, input, opts \\ [])` that bypasses trigger records entirely — builds the event and calls `Workflows.create_run/3` directly
- `Workflows.run_workflow_manually(workflow_id, input, opts \\ [])` — new convenience function in the public context; calls `Manual.fire_for_workflow/3` then `start_run/2`
- No DB trigger record required
- `get_run_trace/1` already stores `trigger_type` from `source_event.assigns` — manual implicit runs will show `"manual"` there

**Files to edit:**
- `lib/zaq/engine/workflows/triggers/manual.ex`
- `lib/zaq/engine/workflows.ex`

**Tests to add before implementation:**

```
- run_workflow_manually creates a run with trigger_type :manual
- run_workflow_manually returns {:ok, completed_run} for a valid workflow
- run_workflow_manually returns {:error, :not_found} for unknown workflow_id
```

**Branches/paths validated:**
- No trigger row in DB
- Workflow in `active` status succeeds; `draft`/`archived` workflow returns error

**Mocking plan:** None

**Documentation to update:**
- `docs/services/workflows.md` — document implicit manual execution

---

## Step 6 — Validation, Coverage & Docs

**Functional specifications:**

- Run `mix precommit` — all dialyzer, credo, format checks pass
- Run coverage check — every touched file >= 95%
- Update `docs/services/workflows.md`:
  - Trigger Types table — add `execution_mode`, `max_concurrency`, `on_failure` columns
  - Execution Flow diagram — reflect `TriggerExecutor` as the new orchestration layer
  - Module Responsibilities table — add `TriggerExecutor`
  - Key Invariants — add cycle detection invariant

**Files to edit:**
- `docs/services/workflows.md`

---

## Dependency Order

```
Step 1 (migration)
  └─> Step 2 (schema)
        └─> Step 3 (context API)
              └─> Step 4 (executor + behaviour)
                    └─> Step 5 (implicit manual)
                          └─> Step 6 (validation + docs)
```

---

## Decisions Log

| Decision | Rationale |
|---|---|
| `TriggerBehaviour.fire/2` no longer calls `create_run` | Executor creates runs per-workflow; fire only builds the event. Cleaner separation. |
| Chained triggers always fire (no on_failure for chains) | Deferred — default continue is safe; revisit when a use case requires halting chains |
| Parallel always runs all to completion | User-specified requirement |
| Manual trigger implicit via `run_workflow_manually/3` | No DB row required; BO always shows Run button |
| Cycle detection at chain creation time | Fail-fast at write time is safer than guarding at fire time |
| `position` integer on `trigger_workflows` | Needed for stable serial ordering; populated by caller |
