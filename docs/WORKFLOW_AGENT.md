# Agent Workflow

This document defines the exact loop Claude Code follows on every task —
from receiving a prompt to merging a PR. Follow this without skipping steps.

---

## Phase 1 — Orient

Before writing a single line of code:

1. Read `AGENTS.md` to confirm you have the full map.
2. Identify which docs apply to this task and read them.
3. Read `docs/exec-plans/active/` — check if a plan already exists for this task.
4. Read `docs/exec-plans/tech-debt-tracker.md` — check if this task is tracked debt.
5. Read `docs/QUALITY_SCORE.md` — understand the current state of the domain you're touching.

---

## Phase 2 — Plan

### Simple tasks (single file, single concern)
- State your approach in 2-3 sentences before starting.
- No formal exec plan needed.

### Complex tasks (multiple files, multiple concerns, or architectural changes)
1. Copy `docs/exec-plans/PLAN_TEMPLATE.md` to `docs/exec-plans/active/YYYY-MM-DD-short-description.md`.
2. Fill in: Goal, Context, Approach, Steps, Definition of Done.
3. Commit the plan before writing any code.
4. If the task requires architectural changes not covered in `docs/architecture.md` — stop, write the plan, and wait for human approval before proceeding.

---

## Phase 3 — Implement

Work through the plan steps one at a time:

1. Read the relevant source files using `mcp__serena__get_symbols_overview` before editing.
2. Implement the change.
3. Write or update unit tests covering the change.
4. Run `mix test` — fix all failures before moving to the next step.
5. Update the plan's steps checklist and decisions log as you go.

### Rules during implementation
- One PR per step when possible — keep PRs small and focused.
- Never call Agent, Ingestion, Engine, or Channel modules directly from BO — always use `NodeRouter` (`dispatch/1` preferred; `call/4` deprecated compatibility).
- Never persist sensitive values without encrypting first — see `docs/services/system-config.md`.
- Never bypass Ecto changesets for data mutations.
- If you discover something unexpected, add it to the decisions log before continuing.

---

## Phase 4 — Validate

### Unit validation
1. Run `mix precommit` — fix everything it reports. Never skip or replace it.
2. Run the full unit test suite: `mix test`.
3. Review your own diff — check for dead code, debug statements, and convention violations.

### E2E validation
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
| Spec | What it covers |
|---|---|
| `ingestion.spec.js` | File upload, processing pipeline, job status |
| `system_config.spec.js` | LLM, embedding, SMTP config via BO |
| `knowledge_ops_lead.spec.js` | Knowledge base operations |

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
   - Whether E2E tests were run and passed
   - Link to exec plan or tech debt item if applicable
   - Any decisions made that future agents need to know
4. Respond to all review feedback before merging.
5. Squash and merge when approved.

---

## Phase 6 — Close Out

After merging:

1. Update the plan's status to `completed` and move it to `docs/exec-plans/completed/`.
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
