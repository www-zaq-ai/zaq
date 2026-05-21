# Plan: Workflow Lifecycle Events

## Goal

Introduce a single general `:workflow` event dispatched through the engine for all workflow lifecycle state changes. Any node (channel adapter, BO, AI agent) that wants to observe workflow activity subscribes once to `:workflow` and branches on `event.request.action`. This plan covers only the dispatch side — producing events from the engine. Consumption is the subscriber's concern.

**Depends on:** `human-in-the-loop.md` for the `"run.waiting"` action (Step 5 of that plan already dispatches it as part of `WorkflowAgent` changes). This plan adds the remaining lifecycle actions and establishes the convention formally.

## Event Convention

All workflow events share `name: :workflow`. The operation is encoded in `event.request.action`.

```elixir
Event.new(%{action: "workflow.created",  workflow_id: id},                  :engine, name: :workflow)
Event.new(%{action: "run.started",       run_id: id, workflow_id: wid},     :engine, name: :workflow)
Event.new(%{action: "run.completed",     run_id: id, workflow_id: wid},     :engine, name: :workflow)
Event.new(%{action: "run.failed",        run_id: id, workflow_id: wid},     :engine, name: :workflow)
Event.new(%{action: "run.waiting",       run_id: id, workflow_id: wid,
            step_name: name, approval_token: token, prompt: prompt},        :engine, name: :workflow)
```

`run.waiting` is dispatched by `WorkflowAgent` (wired in `human-in-the-loop.md`). This plan wires the rest.

## Scope

| Module / File | Change |
|---|---|
| `lib/zaq/engine/workflows/workflow_agent.ex` | **MODIFY** — dispatch `run.started`, `run.completed`, `run.failed` (three dispatch points: `with` success, `finalize/2` completed branch, `finalize/2` failed branch, and `else` branch) |
| `lib/zaq/engine/workflows.ex` | **MODIFY** — dispatch `workflow.created` from `create_workflow/1` |
| `lib/zaq/engine/api.ex` | **VERIFY ONLY** — `handle_event/3` clause for `:workflow` already exists at line 304; confirm it is already a passthrough before touching. No change expected. |
| `docs/services/workflows.md` | **UPDATE** — new Workflow Events section |

## Pre-Planning Audit

- [x] `WorkflowAgent` already has `Logger.info` at run start, finalize — dispatch points are co-located with existing log calls.
- [x] `Workflows.create_workflow/1` is the single DB write point for workflow creation — correct place for `workflow.created` dispatch.
- [x] `Zaq.NodeRouter.dispatch/1` is the dispatch mechanism — confirmed from `NodeRouter` moduledoc.
- [x] `Engine.Api.handle_event/3` already has a catch-all or per-name clause added in `human-in-the-loop.md`. Lifecycle events are fire-and-forget; no response handling needed in `Engine.Api` for them.
- [x] No new modules needed — dispatch is additive to existing modules.

---

## Steps

### Step 1: Private `dispatch_workflow_event/2` helper in `WorkflowAgent`

**Depends on:** none

#### Functional Specifications

Add a private helper to `WorkflowAgent`:

```elixir
defp dispatch_workflow_event(action, body) do
  event = Zaq.Event.new(Map.put(body, :action, action), :engine, name: :workflow)
  Zaq.NodeRouter.dispatch(event)
end
```

Use at four points in `WorkflowAgent`:

1. After `update_run(run, %{status: "running", ...})` succeeds (inside the `with` chain):
   ```elixir
   dispatch_workflow_event("run.started", %{run_id: run.id, workflow_id: run.workflow_id})
   ```
2. In `finalize/2` after `update_run(%{status: "completed", ...})`:
   ```elixir
   dispatch_workflow_event("run.completed", %{run_id: run.id, workflow_id: run.workflow_id})
   ```
3. In `finalize/2` after `update_run(%{status: "failed", ...})`:
   ```elixir
   dispatch_workflow_event("run.failed", %{run_id: run.id, workflow_id: run.workflow_id})
   ```
4. In the `else` branch of `execute/1` (reached when `DagBuilder.build/2` fails after the run
   was already transitioned to `"running"`):
   ```elixir
   dispatch_workflow_event("run.failed", %{run_id: run.id, workflow_id: run.workflow_id})
   ```
   This path never reaches `finalize/2`, so without an explicit dispatch here `run.started`
   fires but `run.failed` never does.

#### Tests to add before implementation

Extend `test/zaq/engine/workflows/workflow_agent_test.exs`:
- Successful run → `"run.started"` and `"run.completed"` events dispatched (assert `NodeRouter.dispatch/1` called with correct action and run_id).
- Failed run (step failure) → `"run.started"` and `"run.failed"` events dispatched.
- Failed run (DAG build failure) → `"run.started"` and `"run.failed"` events dispatched (exercises the `else` branch; `finalize/2` is never called in this path).
- Paused run → `"run.started"` dispatched, no `"run.completed"` or `"run.failed"`.

#### Branches / paths validated

- Complete run: started + completed.
- Failed run via step failure (finalize path): started + failed.
- Failed run via DAG build failure (else branch): started + failed.
- Paused run: started only.
- `run.waiting` already covered in `human-in-the-loop.md`.

#### Mocking plan

Mock `Zaq.NodeRouter.dispatch/1` in WorkflowAgent tests via `Mox` or `Application.put_env` stub to capture dispatched events without real routing side-effects. This is an internal ZAQ boundary call — acceptable to stub at the NodeRouter level for unit isolation.

#### Documentation to update

- `@moduledoc` on `WorkflowAgent`: add **Lifecycle Events** section listing dispatched actions.

---

### Step 2: `workflow.created` dispatch from `Workflows` context

**Depends on:** Step 1 (for context; `dispatch_workflow_event/2` is private to `WorkflowAgent` and cannot be shared — inline the dispatch call directly in `create_workflow/1` rather than extracting a shared helper)

#### Functional Specifications

In `Zaq.Engine.Workflows.create_workflow/1` (or `create_workflow/2`), after the DB insert succeeds, dispatch:

```elixir
Zaq.NodeRouter.dispatch(
  Zaq.Event.new(%{action: "workflow.created", workflow_id: workflow.id}, :engine, name: :workflow)
)
```

Dispatch is best-effort — a dispatch failure must not roll back the DB transaction. Dispatch happens after the transaction commits.

#### Tests to add before implementation

Extend `test/zaq/engine/workflows/workflows_test.exs`:
- `create_workflow/1` success → `"workflow.created"` event dispatched with correct `workflow_id`.
- `create_workflow/1` failure (invalid changeset) → no event dispatched.

#### Branches / paths validated

- Happy path: workflow created, event dispatched.
- Invalid changeset: no event, no crash.

#### Mocking plan

Same NodeRouter stub as Step 1.

#### Documentation to update

- `@doc` on `create_workflow/1`: note that `"workflow.created"` is dispatched on success.

---

### Step 3: Documentation

**Depends on:** Steps 1, 2

- `docs/services/workflows.md`:
  - New section **Workflow Events**:
    - Event name: `:workflow`
    - Table of all actions, their source module, and payload fields.
    - Subscriber pattern: dispatch `Event.new(..., :engine, name: :workflow)` and handle `action` in the body.
  - Execution Flow diagram: add dispatch calls after each status transition.
  - Key Invariants: dispatch failures must not affect run state (fire-and-forget).

---

## Security Checklist

Not applicable — lifecycle events carry only run_id, workflow_id, and step metadata. No person_id or sensitive data in event bodies.

---

## Coverage Policy

| File | Target |
|---|---|
| `workflow_agent.ex` | ≥ 95% |
| `workflows.ex` | ≥ 95% |

---

## Definition of Done

- [ ] Tests written before implementation per step
- [ ] All tests passing (`mix test`)
- [ ] Coverage ≥ 95% per file
- [ ] `mix precommit` passes
- [ ] `docs/services/workflows.md` updated with Workflow Events section

---

## Decisions Log

**Fire-and-forget dispatch — dispatch failures do not affect run state.**
Workflow execution correctness must not depend on downstream event consumers. A subscriber crashing or a NodeRouter timeout must not roll back a completed run.

**Single `:workflow` event name for all actions.**
Subscribers register once. The `action` field in the body is the discriminator. Adding a new lifecycle action requires no subscriber re-registration.

**`run.waiting` wired in `human-in-the-loop.md`, not here.**
The `WaitingForApproval` rescue block in `WorkflowAgent` is the only correct dispatch point for `run.waiting`. Duplicating it here would create drift risk. This plan only adds the remaining actions.
