# Execution Plan

## Plan: Issue 229 - Standardized Role Boundaries

**Date:** 2026-04-16
**Author:** OpenCode (gpt-5.3-codex)
**Status:** `active`
**Related debt:** N/A
**PR(s):** TBD

---

## Goal

Introduce an event-based internal boundary contract for cross-node role communication so multi-node behavior is explicit, typed, and consistent across services. Done means `Zaq.Event` and `Zaq.EventHop` exist with tests, role API modules (`Zaq.{Role}.Api`) implement `Zaq.InternalBoundaries`, `NodeRouter.call/4` remains available but is marked deprecated and internally bridged to the new event path, and all impacted module docs plus architecture/service markdown docs are updated to match implementation.

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/agent.md`
- [x] `docs/services/channels.md`
- [x] `docs/services/engine.md`
- [x] `docs/WORKFLOW_AGENT.md`
- [x] Existing code reviewed:
  - `lib/zaq/node_router.ex`
  - `lib/zaq/engine/messages/incoming.ex`
  - `lib/zaq/engine/messages/outgoing.ex`
  - `lib/zaq/agent/pipeline.ex`
  - `test/zaq/node_router_test.exs`
  - `test/zaq/engine/messages/incoming_test.exs`
  - `test/zaq/agent/pipeline_test.exs`
  - `test/zaq/channels/router_test.exs`

Issue context validated:
- Issue `#229` body and comments were reviewed and aligned.
- Follow-up dependency on issue `#190` acknowledged.

---

## Approach

Use an incremental compatibility-first migration. Add the new event contract and role API modules first, then add router dispatch support, and finally adapt existing call sites gradually. Keep `NodeRouter.call/4` to avoid breaking current callers, but mark it `@deprecated` and route through the new event dispatch internals. This avoids a big-bang migration while letting tests and docs evolve in lockstep.

Key scope decisions for this issue:
- `NodeRouter.call/4` is retained as deprecated (explicit user decision).
- Async/sync remains represented on hop metadata (`Zaq.EventHop.type`).
- `timeout` lives in `event.opts` for v1.
- `halted/errors` workflow orchestration concerns are deferred to step 2 / follow-up issue.
- `actor` is included in v1 event context (preferably as dedicated field; fallback in assigns if needed).

---

## Steps

Break the work into small, independently completable steps. Each step should be
completable in a single PR. Check off as you go.

- [ ] Step 1: Add core boundary contracts
  - Add `lib/zaq/event.ex` with v1 fields and type specs.
  - Add `lib/zaq/event_hop.ex` with `destination`, `type`, `timestamp`.
  - Add `lib/zaq/internal_boundaries.ex` behavior with `handle_event/3` callback.
  - Add unit tests for struct defaults, enforce_keys, and type expectations.

- [ ] Step 2: Add role API modules and compatibility adapters
  - Add `Zaq.Agent.Api`, `Zaq.Engine.Api`, `Zaq.Ingestion.Api`, `Zaq.Channels.Api`.
  - Implement `handle_event/3` with thin delegation to existing service modules.
  - Cover each API module with focused tests for event in/out behavior.

- [ ] Step 3: Extend NodeRouter with event dispatch
  - Add event dispatch path (role resolution + local/remote execution).
  - Keep `call/4` and `call/5`; mark as `@deprecated` and bridge to event dispatch.
  - Keep existing error contract where feasible (`{:error, {:rpc_failed, node, reason}}`).
  - Update `test/zaq/node_router_test.exs` for legacy + event paths.

- [ ] Step 4: Migrate first integration callers
  - Migrate high-value call sites (Agent pipeline and channel bridges) to event path.
  - Keep output behavior stable (`Incoming`/`Outgoing` still valid boundary structs).
  - Update affected unit/integration tests.

- [ ] Step 5: Documentation and deprecation guidance
  - Update module docs in NodeRouter and new event/api modules.
  - Update markdown docs: `docs/architecture.md`, `docs/conventions.md`,
    `docs/services/agent.md`, `docs/services/channels.md`, `docs/services/engine.md`.
  - Document migration guidance: prefer event dispatch; `call/4` deprecated and temporary.

- [ ] Step 6: Validate and ship
  - Run `mix test` during each step.
  - Run `mix precommit` before final PR merge.
  - Ensure no doc/code drift remains for role-boundary behavior.

---

## Decisions Log

Record decisions made during implementation. Future agents need this context.

| Decision | Rationale | Date |
|---|---|---|
| Keep `NodeRouter.call/4` but mark deprecated | User explicitly requested compatibility during migration | 2026-04-16 |
| Use incremental migration (not big-bang) | Reduces risk and keeps test suite stable while introducing new boundary contract | 2026-04-16 |
| Keep `timeout` in `event.opts` for v1 | Matches issue discussion and avoids premature expansion of core struct surface | 2026-04-16 |
| Defer workflow-level `halted/errors` orchestration | Out of v1 boundary contract scope; track as follow-up step/issue | 2026-04-16 |

---

## Blockers

List anything blocking progress and who/what can unblock it.

| Blocker | Owner | Status |
|---|---|---|
| Confirm canonical location of `actor` (top-level field vs assigns) | Maintainers | open |
| Confirm exact event dispatch function name/signature (`dispatch/1` vs variants) | Maintainers | open |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
