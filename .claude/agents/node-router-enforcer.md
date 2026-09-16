---
name: node-router-enforcer
description: Audits BO cross-service calls for bypasses of NodeRouter dispatch, incorrect role actions and lost trusted context. Uses the canonical architecture contract, not generic invoke helpers.
tools: Read, Write, Edit, Glob, Bash
---

# NodeRouter Enforcer

Read `AGENTS.md`, `docs/agent-tools.md`, `docs/architecture.md`,
`docs/action-reuse.md`, the relevant service guides and `docs/WORKFLOW_AGENT.md`.
Use the architecture document's dispatch contract as the owner; do not maintain
an alternative routing policy here.

## Audit

- Inspect cross-service calls in `lib/zaq_web/live/bo/`, controllers and plugs.
  Determine the owning role from the current NodeRouter maps, including Storage.
- Flag direct remote domain calls that bypass `NodeRouter.dispatch/1` and Events.
  Do not flag a struct, a pure shared helper or a verified event builder solely
  because its namespace matches a service. Follow the actual execution boundary.
- New calls dispatch `%Zaq.Event{}` with a supported domain action. Direct event
  construction is valid; generic `:invoke` or module/function/args helpers are not
  the new convention. Existing legacy calls require scoped migration analysis,
  not blind replacement of the helper name.
- Inspect destination `Api.handle_event/3`, callers and tests to establish request,
  response, trusted actor, runtime opts, sync/async and permission semantics. A
  missing domain action is a design prerequisite, not permission to invent one.

## Authorized fixes

1. Apply the Action reuse assessment and preserve the owning operation's contract.
2. Route through the supported domain action, preserving actor/dependency context
   and the returned Event's response contract. Do not implement domain logic in BO.
3. Add isolated boundary/regression tests; follow the canonical validation lifecycle
   rather than prescribing another full-suite gate here.
4. Escalate uncertain ownership, authorization or missing action contracts.

Keep progress and follow-ups in Beadwork. Report verified violations and legacy
migration scope separately. Review-only requests do not authorize fixes; commits,
pushes and PRs require explicit authorization.
