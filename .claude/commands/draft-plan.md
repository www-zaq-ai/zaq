# Draft Implementation Plan

Produce a structured execution plan for the requested feature or task, following `docs/exec-plans/PLAN_STRATEGY.md`. Persist it as Beadwork issues and dependencies, not plan files.

## What I do

1. **Clarify scope** — confirm the task description and identify affected domains before anything else.
2. **Run a pre-planning infrastructure audit** — follow `docs/action-reuse.md`; inspect existing Actions/tools, Registry entries, workflow Steps, domain APIs, relevant tests, and the `@moduledoc` of every module in scope. Read relevant service docs. Reuse or extend existing infrastructure rather than bypassing it; a supplied roadmap does not waive discovery.
3. **Create or reuse Beadwork issues** using the structure below: at least one issue per step, titles prefixed with `[{issueId}]`. Run `bw prime` and check existing issues first.
4. **Wire and validate dependencies** — proposed missing essential Action issues block their consumers. Confirm only intended roots are ready before handing off. If Beadwork is unavailable, report the blocker; do not substitute a plan file.

---

## Beadwork Description Structure

Keep goal, scope, audit, sequencing graph, and decisions in the parent issue;
put each step's specifications and assessment in its own issue. Follow the
feature E2E approval gate in PLAN_STRATEGY when planning UI work.

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
- [ ] Action reuse decisions recorded with source evidence; missing essential Action issues block consumers

## Steps

### Step N: <Title>
**Depends on:** Step X (or "none")

#### Functional Specifications
- Bullet list of behavior this step delivers.
- Public function signatures (include `opts \\ []` only at boundaries resolving runtime dependencies, per conventions).

#### Action reuse assessment
- Operation and candidate module paths/APIs/search evidence.
- Decision: reuse / extend / new Action / local-only; rationale and owner.
- Contract: inputs, outputs, errors, actor/permissions, side effects, retry/idempotency, dependencies where relevant.
- Consumers: code / agent tool / workflow applicability, execution boundary, explicit exposure decision.
- Verification: existing tests to preserve; contract, failure, permission, consumer and relevant property tests.
- Proposed missing-Action prerequisite issue(s); or not applicable with a reason if no operations change.

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

## Testing and Coverage Handoff
- During implementation, cover critical behavior, failure paths, permissions, and regressions without a numerical coverage gate.
- Preserve async-testable boundaries, injected configuration/dependencies, and isolated state.
- After all implementation issues are tackled and PR review is approved, invoke `coverage-upper` before merging; numerical targets remain in its coverage-specific instructions.
- Record coverage-phase exceptions and follow-up work, and review any resulting changes before merging.

---

## Definition of Done
- [ ] Step-level functional specs written before implementation
- [ ] Step-level tests written before implementation
- [ ] All tests passing
- [ ] Critical paths tested and post-review `coverage-upper` phase complete before merging
- [ ] `mix precommit` passes via context-mode with a 15-minute (900,000 ms) execution timeout; only a concise result is returned
- [ ] Docs updated

---

## Decisions Log
*(Record key trade-offs, rejected alternatives, and rationale as the plan evolves)*
```

---

## Constraints

- Steps must be ordered by dependency: primitives before consumers.
- No diamond dependencies unless required and justified.
- Do NOT use plan files or inline chat as the durable plan — persist Beadwork issues and dependencies.
- Do NOT start implementation — this skill produces the plan only.
- Return the issue IDs and a concise summary of the dependency sequence and reuse decisions.
