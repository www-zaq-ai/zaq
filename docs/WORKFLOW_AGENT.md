# Agent Workflow

This document owns the workflow and validation/approval lifecycle for every coding agent —
from receiving a prompt to merging a PR. Follow this without skipping steps.

---

## Phase 1 — Orient

Before writing a single line of code:

1. Read `AGENTS.md` once to route the task; reuse unchanged instructions already in context.
2. Read required sections of applicable policy/service documents before affected work. Links are not imports; do not load the entire map. Tool routing is owned by [agent tools](agent-tools.md). After compaction, recover applicable policies and verify current files, Git and Beadwork before acting. Delegation must explicitly require applicable policy paths when not inherited.
3. Run `bw prime`.
4. Check existing Beadwork issues to confirm whether planning work already exists for this task.
5. For tracked-debt work, consult the relevant entries in `docs/exec-plans/tech-debt-tracker.md`.
6. For domain changes, consult the relevant section of `docs/QUALITY_SCORE.md`.
7. Apply [the Action reuse gate](action-reuse.md): identify affected executable operations and inspect existing Actions/tools and domain APIs before designing a solution. Record not applicable with a reason for tasks without operation changes.

---

## Phase 2 — Plan

Every task must record an `Action reuse assessment` per affected operation using
[the canonical guide](action-reuse.md). Include candidates, decision, contract,
consumers/execution boundary, and verification. Missing essential operations need
proposed Action issues that block their consumer steps, not hidden feature-specific
helpers. A supplied roadmap does not waive discovery. A plan without this evidence
(or justified not-applicable assessment) is not ready to execute.

### Simple tasks (single file, single concern)

- State your approach in 2-3 sentences before starting.
- Create one Beadwork issue for the task before coding.

### Complex tasks (multiple files, multiple concerns, or architectural changes)

1. Break the work into explicit implementation steps.
2. Create Beadwork issues for the plan: at least one issue per step (create more when a step should be split for safe delivery/review).
   - Split one step into multiple issues when any of these apply: different owning module/domain, independent test surface, different deploy/review risk, or expected effort over one day.
3. Prefix every planned issue title with `[{issueId}]`.
4. Link dependencies between the created issues to represent execution order.
   - Planned dependency graph must be a DAG: no cycles, and no diamond dependencies unless they are necessary and explained in issue notes.
5. Validate the dependency graph before coding and confirm only intended root issues are ready while dependents remain blocked by prerequisites.
6. Start implementation only after issue creation and dependency wiring.
7. If the task requires architectural changes not covered in `docs/architecture.md` — stop, create the related Beadwork issue(s), and wait for human approval before proceeding.

For feature work, assess E2E need and follow the
[feature E2E approval gate](testing-approach.md#feature-e2e-approval-gate).
When needed, create/reuse one E2E issue and wire implementation → human UX/UI
approval → E2E dependencies per `docs/exec-plans/PLAN_STRATEGY.md`.

---

## Phase 3 — Implement

Work through the planned Beadwork issues one at a time:

1. Follow [the tool boundary](agent-tools.md#tool-boundaries) to inspect the affected source or documentation.
2. Implement the change with a symbol-aware edit when supported, or the host-required patch/edit tool. Retrieve only the code/text needed for that edit.
3. Write or update unit tests covering the change.
4. Focus tests on critical behavior, failure paths, permissions, and regressions rather than a numerical coverage ratio. Keep code async-testable through injected configuration/dependencies and isolated state; preserve the guidance in `docs/testing-approach.md`.
5. Apply `docs/testing-approach.md`: add property tests when the change touches invariants, broad input spaces, normalization, or permission/safety defaults.
6. Complete the [issue validation checks](#unit-validation) before marking each issue complete.
7. Update the active Beadwork issue notes/description with decisions and progress as you go.
8. Keep the feature's E2E issue scenarios and approval status current after each
   relevant iteration. Defer new/substantially rewritten feature E2E until final
   implementation and explicit human UX/UI approval; minimal repairs to existing
   tests must preserve assertions and intent. See the testing handbook's gate.

### Rules during implementation

- One PR per step when possible — keep PRs small and focused.
- Before coding each step, recheck its Action reuse assessment against current source. Update decisions and prerequisites before changing direction; reuse/extend existing operations instead of adding parallel flows. Preserve execution, authorization, and NodeRouter boundaries per `docs/action-reuse.md`.
- Never call Agent, Ingestion, Engine, or Channel modules directly from BO.
- For cross-service invoke calls, always use role/channel Events helpers instead of building `%Zaq.Event{}` inline and dispatching manually:
  - `Zaq.Agent.Events.build_and_dispatch_invoke_event/3`
  - `Zaq.Engine.Events.build_and_dispatch_invoke_event/3`
  - `Zaq.BO.Events.build_and_dispatch_invoke_event/3`
  - `Zaq.Channels.Events.build_and_dispatch_*`
- Never persist sensitive values without encrypting first — see `docs/services/system-config.md`.
- Never bypass Ecto changesets for data mutations.
- If you discover something unexpected, add it to the decisions log before continuing.

---

## Phase 4 — Validate

### Unit validation

1. After each issue, run `mix q` through Context Mode. It includes formatting; do not run `mix format` separately. Keep logs in Context Mode and return only concise results.
2. Run specific isolated tests confirming the developed feature and relevant failure/regression cases. `mix q` does not replace these tests. Fix failures before completing the issue; documentation-only work needs no application tests.
3. Reserve `mix precommit` for the [final gate](#phase-6--coverage-and-merge), not each issue. Numerical coverage targets remain in that dedicated coverage phase.
4. Review your own diff — check for dead code, debug statements, and convention violations.
5. Apply the review gate in `docs/action-reuse.md`: verify reuse evidence and shared implementations, missing Action prerequisites, justified local-only decisions, and deliberate tool exposure. Resolve unjustified duplication or bypassed boundaries before approval.

### E2E validation

**Execution is distinct from authoring.** During iterations, run existing E2E
where required below; do not generate new feature tests to satisfy this phase.
After the human approval gate, implement the consolidated E2E issue and run the
required validation before declaring the feature complete. A blocked approval
gate is a tracked finalization prerequisite, not a test failure or an E2E waiver.

Run E2E tests when your change touches any of these areas:

- Ingestion pipeline (file upload, processing, status)
- System config (LLM, embedding, SMTP settings)
- Telemetry dashboards
- Knowledge base operations

```bash
cd test/e2e && npm run test
```

This bootstraps a fresh E2E database on port `4002` and runs the full Playwright suite.

#### Reproducing failures with ProcessorState

If you need to test ingestion failure scenarios, use `Zaq.E2E.ProcessorState` to inject
controlled failures into the fake processor:

```elixir
# Make the processor fail N consecutive times
Zaq.E2E.ProcessorState.set_fail(3)

# Reset to normal behavior
Zaq.E2E.ProcessorState.reset()
```

This is only available in `MIX_ENV=test` with `E2E=1`. Use it in `test/support/e2e/bootstrap.exs`
or directly in Playwright `beforeEach` hooks via the E2E controller.

#### E2E spec coverage

| Spec                         | What it covers                               |
| ---------------------------- | -------------------------------------------- |
| `ingestion.spec.js`          | File upload, processing pipeline, job status |
| `system_config.spec.js`      | LLM, embedding, SMTP config via BO           |
| `knowledge_ops_lead.spec.js` | Knowledge base operations                    |

### When to skip E2E

- Pure refactoring with no behavior change — skip E2E, unit tests are sufficient.
- Doc-only changes — skip both E2E and unit tests.
- If E2E bootstrapping fails due to environment issues, note it in the PR and flag for human.

---

## Phase 5 — PR

1. Open a PR targeting `main`.
2. Title must follow Conventional Commits: `feat(scope): description`.
3. PR description must include:
   - What changed and why
   - Action reuse decisions and linked missing-Action issues (or not applicable with a reason)
   - Whether E2E tests were run and passed
   - For iterative feature work: E2E issue link, pending scenarios, and approval
     blocker (or rationale that E2E is unnecessary); for finalization: recorded
     UX/UI approval, completed E2E scope, and validation results
   - Link to Beadwork issue(s) or tech debt item if applicable
   - Any decisions made that future agents need to know
4. Respond to all review feedback before merging.
5. Once all implementation Beadwork issues are tackled and review is approved, proceed to Phase 6 before squash/merge.

---

## Phase 6 — Coverage and Merge

For multi-PR plans, apply this phase to each PR once all implementation issues in that PR are tackled and its review is approved; prerequisite PRs need not wait for downstream implementation.

1. Invoke the `coverage-upper` agent after all implementation issues are tackled and PR review is approved. Numerical coverage targets belong to this dedicated phase, not the development loop.
2. The agent generates a fresh report by running `mix coveralls.json` through context-mode with a **10-minute (600,000 ms) execution timeout**, then runs `mix coverup` only after successful completion. Do not check report age or reuse a stale report after failure/timeout. Follow the agent's remaining planning, delegation, and validation instructions.
3. Record results, exceptions, and follow-up work in Beadwork and the PR. Repeat Phase 4 checks for coverage-phase changes. The review approval that starts coverage is not the final human approval of the completed work.
4. After all implementation, review fixes, required E2E and coverage work is complete, run `mix precommit` through Context Mode with a **15-minute (900,000 ms) execution timeout**. Fix everything it reports and rerun until it passes against the final changes. Do not add a redundant full test run to this gate; issue-level isolated tests remain required. Keep logs in Context Mode and return concise results. If execution is blocked, report the blocker rather than requesting final approval or dumping raw logs.
5. Only after the gate passes, request final human approval with the validation summary. If feedback requires changes, repeat issue-level checks and the final gate before requesting approval again. This applies to documentation-only work too; if coverage is not applicable, record why and proceed to the final gate.
6. Commit, squash or merge only when approved and authorized. Never push directly to `main`. Final approval does not itself authorize a Git mutation the user has not requested.

---

## Phase 7 — Close Out

After merging:

1. Close all completed Beadwork issues and ensure dependencies are resolved.
   Do not close a pending UX/UI approval gate or E2E issue merely because an
   iteration merged. Carry their IDs and pending scope into the handoff; keep the
   overall feature open until required approved E2E finalization is complete.
2. Check off the item in `docs/exec-plans/tech-debt-tracker.md` if applicable.
3. Update `docs/QUALITY_SCORE.md` if the domain grade changed.
4. Update any service doc in `docs/services/` if behavior or architecture changed.

---

## Escalate to Human When

- The task requires architectural changes not covered in existing docs.
- A unit test is failing and you cannot determine the root cause after 2 attempts.
- An E2E test is failing and the failure is unrelated to your change.
- The plan's blocker cannot be resolved by reading existing docs or code.
- A decision has significant product or security implications.
