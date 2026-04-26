# Execution Plan Strategy

This strategy is mandatory for every new execution plan.

---

## Required Inputs

- Start every plan from `docs/exec-plans/PLAN_TEMPLATE.md`.
- Save new plans to `docs/exec-plans/active/YYYY-MM-DD-short-description.md`.
- Do not author ad-hoc plan formats.

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

Each step must include:

1. `Functional specifications covered with associated files to edit/add`
2. `Tests to add before implementation`
3. `Branches/paths validated`
4. `Mocking plan` (only for edge external API calls)
5. `Documentations to update for both code and AGENTS.md related descriptions`

If any item is missing, the step is incomplete and cannot be executed.

---

## Test Strategy (Mandatory)

- Favor integration tests that validate multi-branch behavior.
- Avoid seams as much as possible; test through real module boundaries.
- Use mocks only for edge API calls that are external to Zaq's primitives (separate deps or outside API).
- Keep internal dependencies real unless there is a hard technical constraint.

---

## Coverage Policy (Mandatory)

- Any file added or modified during implementation must reach at least 95% coverage.
- Coverage checks must be part of plan validation before closing the plan.
- If a file cannot meet 95%, document the exact reason and follow-up work in:
  - plan Decisions Log
  - PR description

---

## Definition-of-Done Addendum

A plan is done only when:

- Step-level functional specifications were written before implementation
- Step-level test definitions were written before implementation.
- Required tests were implemented and passing.
- Coverage for every touched file is >= 95%.
- `mix precommit` passes.
