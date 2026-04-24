# Execution Plan Strategy

This strategy is mandatory for every new execution plan.

---

## Required Inputs

- Start every plan from `docs/exec-plans/PLAN_TEMPLATE.md`.
- Save new plans to `docs/exec-plans/active/YYYY-MM-DD-short-description.md`.
- Do not author ad-hoc plan formats.

---

## Test-First Planning Rules

For every implementation step, identify and document tests that must be created
before coding that step.

Each step must include:

1. `Tests to add before implementation`
2. `Branches/paths validated`
3. `Mocking plan` (only for edge external API calls)
4. `Coverage target for touched files` (minimum 95%)

If any item is missing, the step is incomplete and cannot be executed.

---

## Test Strategy (Mandatory)

- Favor integration tests that validate multi-branch behavior.
- Avoid seams as much as possible; test through real module boundaries.
- Use mocks only for edge external API calls.
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

- Step-level test definitions were written before implementation.
- Required tests were implemented and passing.
- Coverage for every touched file is >= 95%.
- `mix precommit` passes.
