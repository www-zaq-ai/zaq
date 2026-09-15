# Execution Plan Strategy

This strategy is mandatory for every new execution plan.

---

## Basic Planning rules

- Steps execution order should be set according to identified dependencies: Step 1 should build the primitives that would be needed by Step 2.
- Cleanly separate concerns between modules based on functional domain requirements (merge when same domain, split if different domain)

---

## Required Inputs

- Planning is tracked in Beadwork issues, not in `docs/exec-plans/active/` files.
- For planned work, create at least one Beadwork issue per step (create more issues when a step must be split).
- Split a step into multiple issues when any of these apply: different owning module/domain, independent test surface, different deploy/review risk, or expected effort over one day.
- Prefix every planned issue title with `[{issueId}]`.
- Encode execution order with issue dependencies in Beadwork.
- Dependency graph requirement: planning dependencies must form a DAG (no cycles). Avoid diamond dependency shapes unless they are required and justified in issue notes.
- Do not use ad-hoc planning formats outside Beadwork.

### Dependency validation checklist (mandatory before implementation)

- Confirm blocked issues match planned prerequisites.
- Confirm only intended root issues are ready.
- Verify both `depends_on` and `blocks` edges are correct for each planned issue.
- Fix dependency direction mistakes before implementation starts.

### Feature E2E lifecycle

Follow [the testing handbook's feature E2E approval gate](../testing-approach.md#feature-e2e-approval-gate).
When E2E is needed, plan one persistent E2E issue and a separate human UX/UI
approval issue. Use this dependency sequence:

`implementation steps → human UX/UI approval → consolidated E2E implementation`

The approval issue stays open until the completed feature is explicitly approved
for E2E finalization. Keep scenarios and prerequisites current across iterations;
never make E2E depend on closure of its parent feature (which needs E2E to finish).
Iteration completion is not feature completion. Preserve the gate in handoffs and
reopen it if material UX/UI changes invalidate approval.

---

## Pre-Planning Infrastructure Audit (Mandatory)

Before writing any step, audit what already exists for the domain being changed.
An agent that skips this will duplicate infrastructure, create parallel code paths, and
generate avoidable review comments.

For agent service work, verify:

- Does `Factory` already cover the LLM call? If yes, use it. If no, extend it — never bypass it.
- Does `Executor.run` already cover the execution path? If yes, route through it.
- Does an `Outgoing` builder already construct the response? If yes, use it or extend it.
- Are provider credentials / URL formatting already handled in `get_ai_provider_credential/1` or `Factory`?

For any domain, verify:

- Read the `@moduledoc` of every module you plan to add code to. Confirm the function fits the module's stated responsibility.
- If a module's `@moduledoc` does not cover your use case, find the correct module first — do not add misplaced code.

**If you cannot answer these questions, read the relevant `docs/services/` file before proceeding.**

---

## Module Responsibility Rules (Mandatory)

Each step must identify which module(s) will own new code. For each module, confirm:

1. The `@moduledoc` covers this responsibility.
2. No existing module already does this.
3. No cross-cutting concern (credentials, URL formatting, permission checks) is being pulled into a domain module.

If a step places temporary code in a non-ideal module (acceptable when tracked), add a `# Temporary:` inline
comment in the code explaining the placement and the condition for moving it. `TODO` tags are blocked by Credo —
use this format instead:

```elixir
# Temporary: <reason it's here>. Move to <target> once <condition>.
```

When detailing the implementation for a module:

- Public function signatures represent boundaries between modules and should be treated with high care, their modifications should be avoided when possible.
- Add `opts \\ []` to a new public function only when that boundary resolves runtime
  dependencies. Do not add speculative opts parameters to pure functions.
- If new feature code reads application/runtime config, route it through `Zaq.Config.get/4` with that `opts` list instead of calling `Application.get_env/3` directly. This keeps production behavior unchanged while allowing async-safe test overrides with `config: TestConfig`.
- Identify nondeterministic and side-effecting dependencies before implementation:
  runtime config, external clients, clocks, randomness, ID generation, storage, process
  names, schedulers, and retry timers.
- Define the production seam for each dependency. Resolve dependencies at the public
  boundary, propagate the established opts/event/context carrier where required, and
  pass resolved modules or values to internal pure functions.
- Confirm planned tests can control dependencies without global mutation or a later
  test-only refactor. Follow `docs/conventions.md` and `docs/testing-approach.md`.

---

## Security Checklist (Required When Touching Permissions)

Any step that touches permission filtering, person_id, skip_permissions, or data access scope must answer:

- Can `person_id: nil` reach this path? If yes, what does it return — and is that correct?
- Is admin/skip-permissions access an explicit opt-in, or could it be triggered implicitly?
- Is the permission bypass tested with a negative case (nil person_id must not grant elevated access)?

**A `nil` person_id is never an implicit permission grant. Explicit opt-in only.**

---

## Test-First Planning Rules

For every implementation step, identify and document tests that must be created
before coding that step.

Exception: define feature E2E scenarios early in the persistent E2E issue, but
defer their implementation until the human approval gate is satisfied. This does
not defer unit, integration, LiveView/component, or property tests. For iteration
steps, `Tests to add before implementation` must distinguish immediate tests from
deferred E2E and link the E2E issue (or record why E2E is not needed).

Each step must include:

1. `Functional specifications covered with associated files to edit/add`
2. `Tests to add before implementation`
3. `Branches/paths validated`
4. `Mocking plan` (only for edge external API calls)
5. `Documentations to update for both code and docs/ related content`

If any item is missing, the step is incomplete and cannot be executed.

---

## Test Strategy (Mandatory)

- Favor integration tests that validate multi-branch behavior.
- Avoid seams as much as possible; test through real module boundaries.
- Use mocks only for edge API calls that are external to Zaq's primitives (separate deps or third party APIs).
- Keep internal dependencies real unless there is a hard technical constraint.

---

## Testing and Coverage Handoff (Mandatory)

- During implementation, test critical behavior, failure paths, permissions, and regressions; do not impose a numerical coverage gate on each step.
- Preserve async-testable boundaries, injected configuration/dependencies, and isolated state so the later coverage pass can add tests safely.
- Plan a dedicated `coverage-upper` handoff after all implementation issues are tackled and PR review is approved, before squash/merge. Numerical targets remain in coverage-specific agents and skills.
- Record coverage-phase exceptions and follow-up work in Beadwork issue notes and the PR description. Review any changes from that phase before merging.

---

## Definition-of-Done Addendum

A plan is done only when:

- Step-level functional specifications were written before implementation
- Step-level test definitions were written before implementation.
- Required tests were implemented and passing.
- Required feature E2E was implemented and validated after recorded human UX/UI
  approval; an iteration may finish with its E2E issue blocked, but the feature
  plan remains open until that finalization is complete.
- Critical paths are tested and the post-review `coverage-upper` phase is complete before merging.
- `mix precommit` passes via context-mode with a 15-minute (900,000 ms) execution timeout; return only a concise result, not full logs.
