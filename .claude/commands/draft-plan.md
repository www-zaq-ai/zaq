# Draft Implementation Plan

Produce a structured execution plan for the requested feature or task, following the ZAQ plan strategy. Write it to `docs/exec-plans/active/<slug>.md`.

## What I do

1. **Clarify scope** — confirm the task description and identify affected domains before anything else.
2. **Run a pre-planning infrastructure audit** — read the `@moduledoc` of every module in scope and the relevant `docs/services/<domain>.md`. Answer: does existing infrastructure (Factory, Executor, Outgoing, NodeRouter, etc.) already cover any part of this? If yes, use or extend it — never bypass it.
3. **Draft the plan file** using the structure below.
4. **Write the file** to `docs/exec-plans/active/<slug>.md`.

---

## Plan File Structure

```
# Plan: <Title>

## Goal
One paragraph: what this plan delivers and why.

## Scope
Modules and files touched. For each module, confirm its @moduledoc covers the responsibility.

## Pre-Planning Audit
- [ ] Existing infrastructure reviewed (list what was found and what will be reused or extended)
- [ ] No parallel code paths introduced
- [ ] Module @moduledoc checked for every target module

## Steps

### Step N: <Title>
**Depends on:** Step X (or "none")

#### Functional Specifications
- Bullet list of behavior this step delivers.
- Public function signatures (include `opts \\ []` on new public functions).

#### Tests to add before implementation
- List of test cases with file path, describe block, and what each case asserts.
- Favor integration tests through real module boundaries.
- Mock only external API calls (third-party or separate deps).

#### Branches / paths validated
- Happy path
- Error / edge cases
- Security path (if applicable)

#### Mocking plan
- What is mocked (if anything) and why.

#### Documentation to update
- Code: `@moduledoc`, `@doc` for new public functions.
- Docs: which `docs/services/<domain>.md` sections change.

---

## Security Checklist
*(Fill only if any step touches permissions, person_id, or data-access scope)*

- [ ] Can `person_id: nil` reach this path? What does it return?
- [ ] Is admin/skip-permissions access explicit opt-in only?
- [ ] Negative case (nil must not grant elevated access) is tested?

---

## Coverage Policy
- Every file added or modified must reach ≥ 95% coverage.
- List files and their expected coverage targets.
- If a file cannot reach 95%, document the exact reason here.

---

## Definition of Done
- [ ] Step-level functional specs written before implementation
- [ ] Step-level tests written before implementation
- [ ] All tests passing
- [ ] Coverage ≥ 95% for every touched file
- [ ] `mix precommit` passes
- [ ] Docs updated

---

## Decisions Log
*(Record key trade-offs, rejected alternatives, and rationale as the plan evolves)*
```

---

## Constraints

- Steps must be ordered by dependency: primitives before consumers.
- No diamond dependencies unless required and justified.
- Do NOT write the plan as inline chat text — always write it to a file.
- Do NOT start implementation — this skill produces the plan only.
- After writing the file, print the path and a 2-sentence summary of the step sequence.
