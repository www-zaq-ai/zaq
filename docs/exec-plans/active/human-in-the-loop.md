# Plan: Human-in-the-Loop Workflow Step (Core)

## Goal

Deliver a `HumanInTheLoop` Jido action that suspends a workflow run awaiting human or agent approval before continuing. This plan covers only the core suspension/approval mechanism. Lifecycle event broadcasting is handled in `workflow-lifecycle-events.md`. Full permission management is handled in `workflow-permissions.md`.

**Scope boundary:** The Engine.Api handler in this plan uses a minimal permission check — `nil` person_id (BO admin) is always allowed; all other callers are initially rejected. The full `Permissions.can?/4` check is wired in `workflow-permissions.md`.

## Scope

| Module / File | Change |
|---|---|
| `lib/zaq/engine/workflows/conditions/waiting_for_approval.ex` | **NEW** |
| `lib/zaq/engine/workflows/workflow_approval.ex` | **NEW** |
| `lib/zaq/engine/workflows/steps/human_in_the_loop.ex` | **NEW** |
| `lib/zaq/engine/workflows/steps/run.ex` | **MODIFY** — add `"waiting"` to `@statuses` |
| `lib/zaq/engine/workflows/action_wrapper.ex` | **MODIFY** — rescue `WaitingForApproval`, inject context |
| `lib/zaq/engine/workflows/workflow_agent.ex` | **MODIFY** — rescue `WaitingForApproval`, transition run to `"waiting"` |
| `lib/zaq/engine/workflows.ex` | **MODIFY** — approval CRUD + `approve_run/4`, `reject_run/4`, `wait_step_run/1` |
| `lib/zaq/engine/api.ex` | **MODIFY** — add `handle_event(event, :workflow, context)` clause |
| `priv/repo/migrations/..._create_workflow_approvals.exs` | **NEW** |
| `docs/services/workflows.md` | **UPDATE** |

## Pre-Planning Audit

- [x] `WorkflowRun` already defines `"waiting"` in `@statuses` — not yet driven. This plan drives it.
- [x] `Step.Run` has no `"waiting"` status and no DB check constraint — adding to `@statuses` only, no migration.
- [x] `ConditionNotMet` pattern reviewed — `WaitingForApproval` follows the same `defexception` shape.
- [x] `ActionWrapper` rescues `ConditionNotMet` and re-raises — same pattern for `WaitingForApproval`.
- [x] `Engine.Api.handle_event/3` pattern confirmed — add `:workflow` clause following existing shape.
- [x] `approve_run/4` transitions to `"paused"` before calling `resume_run/2` — reuses existing guard without forking it.
- [x] `ActionWrapper` strips `@wrapper_keys` before calling `mod.run/2` — `run_id`/`step_name` must be injected into context, not params.
- [x] No parallel code paths — `approve_run/4` / `reject_run/4` called only from `Engine.Api`.

---

## Steps

### Step 1: `WaitingForApproval` exception

**Depends on:** none

#### Functional Specifications

- Module: `Zaq.Engine.Workflows.Conditions.WaitingForApproval`
- File: `lib/zaq/engine/workflows/conditions/waiting_for_approval.ex`
- `defexception [:step_name, :run_id, :approval_token]`
- `message/1` → `"waiting_for_approval:#{step_name} (run_id=#{run_id})"`

#### Tests to add before implementation

File: `test/zaq/engine/workflows/conditions/waiting_for_approval_test.exs`
- `message/1` returns correctly formatted string including step_name and run_id.
- Exception can be raised and rescued via `rescue e in WaitingForApproval`.
- All three fields (`step_name`, `run_id`, `approval_token`) are accessible after rescue.

#### Branches / paths validated

- Happy path: raise + rescue succeeds, fields intact.

#### Mocking plan

None.

#### Documentation to update

- `@moduledoc false` (infrastructure module, no public docs needed).

---

### Step 2: `WorkflowApproval` schema + migration

**Depends on:** none

#### Functional Specifications

- Module: `Zaq.Engine.Workflows.WorkflowApproval`
- File: `lib/zaq/engine/workflows/workflow_approval.ex`
- Table: `workflow_approvals`
- Fields:
  - `id` — binary_id PK
  - `workflow_run_id` — FK → `workflow_runs`, on_delete: :delete_all, not null
  - `step_name` — string, not null
  - `approval_token` — string, not null
  - `prompt` — string, nullable
  - `status` — string, default `"pending"`, enum: `~w(pending approved rejected)`
  - `decision` — map, nullable
  - `approved_by` — string, nullable
  - `approved_at` — utc_datetime, nullable
  - timestamps
- Indexes:
  - `unique_index(:workflow_approvals, [:workflow_run_id, :step_name])` — one approval per step per run
  - `unique_index(:workflow_approvals, [:approval_token])`
- `changeset/2` — validates required fields, `validate_inclusion(:status, @statuses)`, foreign key constraint.
- `statuses/0` — returns `@statuses`.

#### Tests to add before implementation

File: `test/zaq/engine/workflows/workflow_approval_test.exs`
- Valid changeset with all fields.
- Missing `workflow_run_id` or `step_name` → invalid.
- Invalid status value → invalid.
- Duplicate `approval_token` → unique constraint error.
- Duplicate `(workflow_run_id, step_name)` → unique constraint error.

#### Branches / paths validated

- Happy path: valid insert.
- Constraint violations for both unique indexes.

#### Mocking plan

None.

#### Documentation to update

- `@moduledoc` on `WorkflowApproval` explaining fields and statuses.

---

### Step 3: Add `"waiting"` to `Step.Run` statuses

**Depends on:** none

#### Functional Specifications

- File: `lib/zaq/engine/workflows/steps/run.ex`
- Change `@statuses` to `~w(running paused waiting completed failed skipped)`.
- Update `@moduledoc` — add: `"waiting"` = action suspended pending human approval.

#### Tests to add before implementation

Extend `test/zaq/engine/workflows/workflow_run_test.exs`:
- `changeset/2` accepts `status: "waiting"`.

#### Branches / paths validated

- Changeset validates `"waiting"` as a valid status.
- Changeset still rejects unknown statuses.

#### Mocking plan

None.

#### Documentation to update

- `@moduledoc` on `Step.Run`.

---

### Step 4: `HumanInTheLoop` action

**Depends on:** Steps 1, 2

#### Functional Specifications

- Module: `Zaq.Engine.Workflows.Steps.HumanInTheLoop`
- File: `lib/zaq/engine/workflows/steps/human_in_the_loop.ex`

```elixir
use Jido.Action,
  name: "human_in_the_loop",
  schema: [prompt: [type: :string, required: false]],
  output_schema: [
    approved: [type: :boolean, required: true],
    decision: [type: :map, required: false],
    approved_by: [type: :string, required: false]
  ]

use Zaq.Engine.Workflows.Action
```

`run/2` implementation:
1. Read `run_id` and `step_name` from `context` (injected by ActionWrapper in Step 5).
2. Guard: raise `ArgumentError` if either is nil.
3. Generate `approval_token = Ecto.UUID.generate()`.
4. Call `Workflows.create_approval(%{workflow_run_id: run_id, step_name: step_name, approval_token: approval_token, prompt: params[:prompt], status: "pending"})`.
5. Raise `%WaitingForApproval{step_name: step_name, run_id: run_id, approval_token: approval_token}`.

#### Tests to add before implementation

Extend `test/zaq/engine/workflows/steps/workflow_steps_test.exs`:
- `HumanInTheLoop.run/2` raises `WaitingForApproval` with correct `step_name`, `run_id`, `approval_token`.
- Creates a `WorkflowApproval` record with `status: "pending"` and the given `approval_token`.
- Stores `prompt` from params when provided.
- Works when `prompt` is nil.
- Raises `ArgumentError` when `run_id` or `step_name` absent from context.

#### Branches / paths validated

- Happy path: approval created, exception raised.
- Missing context keys: early ArgumentError.
- Prompt optional: no error when nil.

#### Mocking plan

None.

#### Documentation to update

- `@moduledoc` on `HumanInTheLoop` explaining the suspend/approve flow.
- `@doc` on `run/2`.

---

### Step 5: `ActionWrapper` + `WorkflowAgent` suspension

**Depends on:** Steps 1, 3

#### Functional Specifications

**`ActionWrapper` changes** (`lib/zaq/engine/workflows/action_wrapper.ex`):

1. Before calling `mod.run(stripped_params, context)`, enrich context:
   ```elixir
   enriched_context = Map.merge(context || %{}, %{run_id: run_id, step_name: step_name})
   mod.run(stripped_params, enriched_context)
   ```
2. Add rescue clause for `WaitingForApproval` alongside existing `ConditionNotMet`:
   ```elixir
   rescue
     e in WaitingForApproval ->
       Workflows.wait_step_run(step_run)
       reraise e, __STACKTRACE__
   ```

**`WorkflowAgent` changes** (`lib/zaq/engine/workflows/workflow_agent.ex`):

Add `rescue` clause in `execute_dag_with_pause/3` alongside existing `catch`:
```elixir
rescue
  e in WaitingForApproval ->
    Logger.info("[workflow] run waiting for human approval",
      run_id: run.id, step_name: e.step_name, token: e.approval_token)
    {:ok, updated_run} = Workflows.update_run(
      Workflows.get_run!(run.id), %{status: "waiting"}
    )
    {:ok, updated_run}
```

#### Tests to add before implementation

Extend `test/zaq/engine/workflows/action_wrapper_test.exs`:
- When wrapped action raises `WaitingForApproval`:
  - StepRun is updated to `"waiting"`.
  - Exception is re-raised to caller.
- `run_id` and `step_name` are present in context received by `mod.run/2`.
- Other exceptions still mark StepRun as `"failed"`.

Extend `test/zaq/engine/workflows/workflow_agent_test.exs`:
- Run with HumanInTheLoop step → returns `{:ok, run}` with `run.status == "waiting"`.
- StepRun for HumanInTheLoop step is `"waiting"`.
- Completed steps prior to HumanInTheLoop remain `"completed"`.

#### Branches / paths validated

- Suspension happy path: run "waiting", StepRun "waiting".
- Prior steps unaffected.
- Non-`WaitingForApproval` exceptions still propagate as errors.

#### Mocking plan

None — tests use real DB and real module calls through existing test action helpers.

#### Documentation to update

- `@moduledoc` on `ActionWrapper`: add `WaitingForApproval` handling section.
- `@moduledoc` on `WorkflowAgent`: update Pause/Resume section to include `"waiting"`.

---

### Step 6: `Workflows` context — approval CRUD and state transitions

**Depends on:** Steps 2, 3, 5

#### Functional Specifications

New functions in `Zaq.Engine.Workflows`:

```elixir
@spec create_approval(map(), keyword()) ::
        {:ok, WorkflowApproval.t()} | {:error, Ecto.Changeset.t()}

@spec get_approval_by_token(String.t(), keyword()) :: WorkflowApproval.t() | nil

@spec wait_step_run(StepRun.t(), keyword()) ::
        {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}

@spec approve_run(WorkflowRun.t(), WorkflowApproval.t(), map(), String.t() | nil, keyword()) ::
        {:ok, WorkflowRun.t()} | {:error, :not_waiting | :already_decided | term()}

@spec reject_run(WorkflowRun.t(), WorkflowApproval.t(), String.t(), String.t() | nil, keyword()) ::
        {:ok, WorkflowRun.t()} | {:error, :not_waiting | :already_decided | term()}
```

**`wait_step_run/2`:** Updates StepRun status to `"waiting"`.

**`approve_run/5(run, approval, decision, approved_by, opts \\ [])`:**
1. `run.status != "waiting"` → `{:error, :not_waiting}`.
2. `approval.status != "pending"` → `{:error, :already_decided}`.
3. Transaction:
   - Update `WorkflowApproval` → `status: "approved"`, `decision`, `approved_by`, `approved_at: DateTime.utc_now(:second)`.
   - Find `"waiting"` StepRun for `(run.id, approval.step_name)` → update to `"completed"`, `results: %{approved: true, decision: decision, approved_by: approved_by}`.
   - Update `WorkflowRun` → `status: "paused"`.
4. Call `resume_run(run)` → ActionWrapper finds completed StepRun, returns cached approval data to downstream steps.

**`reject_run/5(run, approval, reason, approved_by, opts \\ [])`:**
1–2. Same guards.
3. Transaction:
   - Update `WorkflowApproval` → `status: "rejected"`, `approved_by`, `approved_at`.
   - Update StepRun → `"failed"`, `errors: %{rejected: true, reason: reason}`.
   - Update `WorkflowRun` → `"failed"`, `finished_at: DateTime.utc_now(:second)`.
4. Return `{:ok, failed_run}` — does not call resume.

#### Tests to add before implementation

Extend `test/zaq/engine/workflows/workflows_test.exs`:
- `approve_run/5`: success, `:not_waiting`, `:already_decided`.
- Downstream step receives `%{approved: true, decision: ..., approved_by: ...}` via ActionWrapper cache.
- `reject_run/5`: success, `:not_waiting`, `:already_decided`, run is `"failed"`, downstream step not executed.
- Integration — full DAG `A → HumanInTheLoop → B`:
  - Suspend → approve → run completes, step B executed with approval data.
  - Suspend → reject → run fails, step B not executed.

#### Branches / paths validated

- Approve happy path: full resume through to completion.
- Reject happy path: clean failure.
- Guard rails: wrong state, already decided.
- Idempotency: ActionWrapper skips HumanInTheLoop on resume (completed StepRun found).

#### Mocking plan

None.

#### Documentation to update

- `@doc` for each new public function.
- `@moduledoc` on `Workflows` — mention approval lifecycle.

---

### Step 7: `Engine.Api` — `:workflow` event handler

**Depends on:** Step 6

#### Functional Specifications

Add to `lib/zaq/engine/api.ex`:

```elixir
def handle_event(%Event{} = event, :workflow, _context) do
  case event.request do
    %{action: "run.approve", run_id: run_id, person_id: person_id} = req ->
      decision = Map.get(req, :decision, %{})
      approved_by = to_string(person_id || "admin")
      %{event | response: handle_workflow_approve(run_id, person_id, decision, approved_by)}

    %{action: "run.reject", run_id: run_id, person_id: person_id} = req ->
      reason = Map.get(req, :reason, "rejected")
      approved_by = to_string(person_id || "admin")
      %{event | response: handle_workflow_reject(run_id, person_id, reason, approved_by)}

    _other ->
      event
  end
end
```

**Permission check (minimal — full check deferred to `workflow-permissions.md`):**
- `person_id: nil` → admin, allowed.
- `person_id` present → `{:error, :unauthorized}` until `workflow-permissions.md` wires `Permissions.can?/4`.

This is a deliberate temporary state. Add inline comment:
```elixir
# Temporary: only admin (nil person_id) allowed until workflow-permissions plan wires Permissions.can?/4.
```

**Private helpers:**

```elixir
defp handle_workflow_approve(run_id, person_id, decision, approved_by)
defp handle_workflow_reject(run_id, person_id, reason, approved_by)
```

Each:
1. Guard `person_id` — nil allowed, non-nil returns `{:error, :unauthorized}` (temporary).
2. Load `WorkflowRun` by `run_id`.
3. Load `WorkflowApproval` for run (pending one).
4. Call `Workflows.approve_run/5` or `Workflows.reject_run/5`.

#### Tests to add before implementation

Extend `test/zaq/engine/api_test.exs`:
- `handle_event(event, :workflow, ctx)` with `action: "run.approve"`, `person_id: nil` → success.
- `handle_event` with `action: "run.approve"`, `person_id: some_id` → `{:error, :unauthorized}` (until permissions plan).
- `handle_event` with `action: "run.reject"`, `person_id: nil` → run failed.
- Unknown `action` → event returned unchanged (no crash).
- Missing `run_id` → `{:error, {:invalid_request, ...}}`.

#### Branches / paths validated

- Admin approve/reject: full flow.
- Non-admin: unauthorized (temporary guard).
- Unknown action: no-op passthrough.
- Invalid request shape: error response.

#### Mocking plan

None.

#### Documentation to update

- Inline `# Temporary:` comment in `Engine.Api`.

---

### Step 8: Documentation

**Depends on:** Steps 1–7

- `docs/services/workflows.md`:
  - Module table: add `WorkflowApproval`, `Steps.HumanInTheLoop`, `Conditions.WaitingForApproval`.
  - WorkflowRun status lifecycle: add `waiting → running (on approve)` and `waiting → failed (on reject)`.
  - Step.Run statuses: add `"waiting"`.
  - New section **Human-in-the-Loop**: full suspend → approve/reject flow.
  - Key Invariants: `WaitingForApproval` must not be caught between ActionWrapper and WorkflowAgent.
  - What NOT to Do: do not set `"waiting"` status directly — raise `WaitingForApproval`; do not call `approve_run` outside `Engine.Api`.

---

## Security Checklist

- [x] `nil person_id` = BO admin — explicit opt-in, handled in `Engine.Api` only.
- [x] Non-nil `person_id` → `{:error, :unauthorized}` until `workflow-permissions.md` adds `Permissions.can?/4`.
- [x] Double-approve → `{:error, :already_decided}`.
- [x] `approval_token` = `Ecto.UUID.generate()` — 128-bit, not guessable.
- [x] Downstream step receives `%{approved: true, decision: ...}` only — token never exposed in results.

---

## Coverage Policy

| File | Target |
|---|---|
| `conditions/waiting_for_approval.ex` | 100% |
| `workflow_approval.ex` | 100% |
| `steps/human_in_the_loop.ex` | 100% |
| `steps/run.ex` | ≥ 95% |
| `action_wrapper.ex` | ≥ 95% |
| `workflow_agent.ex` | ≥ 95% |
| `workflows.ex` | ≥ 95% |
| `engine/api.ex` | ≥ 95% |

---

## Definition of Done

- [ ] Tests written before implementation per step
- [ ] All tests passing (`mix test`)
- [ ] Coverage ≥ 95% per file
- [ ] `mix precommit` passes
- [ ] `docs/services/workflows.md` updated
- [ ] `# Temporary:` comment in `Engine.Api` links to `workflow-permissions.md`

---

## Decisions Log

**Permission check deferred to `workflow-permissions.md`.**
Using `Permissions.can?/4` requires loading a `Person` struct and a `Workflow` struct, which introduces its own test surface and security checklist. Keeping it separate makes both plans reviewable independently.

**`"run"` right used for approval (decided, not implemented yet).**
Reuses existing `ResourcePermission.@valid_rights`. No schema change needed.

**`approve_run/5` transitions run to `"paused"` before calling `resume_run/2`.**
Reuses existing guard without forking it. The semantic difference is captured in `WorkflowApproval.status`.

**`WaitingForApproval` is an exception, not a throw.**
`ActionWrapper` uses `rescue` for its crash-safe cursor. A throw would bypass `ActionWrapper`'s rescue block silently. An exception propagates correctly and lets `ActionWrapper` mark the StepRun as `"waiting"` before re-raising.
