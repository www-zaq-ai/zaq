# Execution Plan

---

## Plan: Channels Bridge/Router Consolidation with Async HopEvent ACK Flow

**Date:** 2026-05-07
**Author:** OpenCode (agent)
**Status:** `completed`
**Related debt:** `docs/exec-plans/tech-debt-tracker.md` (Channels Must Do items)
**PR(s):** pending
**Issue chain:** `zaq-y39` -> `zaq-crk` -> (`zaq-4to` + `zaq-dyc`) -> `zaq-gpj` -> `zaq-ohp` -> `zaq-7il`

---

## Goal

Refactor Channels message routing to remove bridge/router redundancy, centralize communication-domain callbacks and generic adapter dispatch in a dedicated `CommunicationBridge`, keep `Zaq.Channels.Bridge` focused on ZAQ-internal incoming orchestration hooks, and enforce async `%Zaq.Event{}`/`EventHop` NodeRouter flow so inbound adapter ACKs and outbound responses follow a single consistent path without bridge-to-NodeRouter reply loops.

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/channels.md`
- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/exec-plans/PLAN_STRATEGY.md`
- [x] Existing code reviewed:
  - `lib/zaq/channels/bridge.ex`
  - `lib/zaq/channels/router.ex`
  - `lib/zaq/channels/api.ex`
  - `lib/zaq/channels/jido_chat_bridge.ex`
  - `lib/zaq/channels/email_bridge.ex`
  - `lib/zaq/channels/web_bridge.ex`
  - `lib/zaq/node_router.ex`
  - `lib/zaq/event.ex`
  - `lib/zaq/event_hop.ex`
  - `lib/zaq/agent/api.ex`
  - `lib/zaq/agent/executor.ex`
  - `lib/zaq/engine/messages/incoming.ex`
  - `lib/zaq/engine/messages/outgoing.ex`

### Infrastructure Audit

Confirm before writing any step - what already exists that this plan must use or extend?

- [x] Existing entry points checked (Factory, Executor, builders, helpers): for channels domain, existing entry points are `Zaq.Channels.Api.handle_event/3`, `Zaq.Channels.Bridge` shared helpers, `Zaq.NodeRouter.dispatch/1`, `%Zaq.Event{}` + `%Zaq.EventHop{}` envelopes; plan extends these instead of creating parallel dispatch paths.
- [x] `@moduledoc` read for every module that will receive new code:
  - `Zaq.Channels.Bridge`
  - `Zaq.Channels.Api`
  - `Zaq.Channels.JidoChatBridge`
  - `Zaq.Channels.EmailBridge`
  - `Zaq.Channels.WebBridge`
  - `Zaq.Agent.Api`
  - `Zaq.Agent.Executor`
- [x] No parallel code path being created where an existing one can be extended: extend existing bridges/API boundary and remove `Zaq.Channels.Router` indirection.
- [x] Provider/credential/URL logic confirmed to stay in its designated module: credentials remain in channel config + adapter modules; no movement into unrelated modules.

---

## Approach

Implement the refactor in dependency order: first establish the target contract and module boundaries, then extract communication-specific routing logic, then simplify `Bridge` into reusable incoming hooks, then migrate API routing and remove the router module, then switch inbound ACK/outbound reply behavior to async hop-based NodeRouter dispatch. Keep bridge implementations transport-focused and enforce canonical `%Incoming{}`/`%Outgoing{}` boundaries.

---

## Steps

- [ ] Step 1 (`zaq-y39`): Baseline contract and flow invariants
  - Module placement check: contract/invariant tests live with channels integration tests and API boundary tests; no domain logic relocation yet.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): add flow-spec tests documenting current/target incoming and outgoing event transitions.
    - [ ] Branch/path coverage:
      - provider bridge resolution success/failure
      - ACK shape for inbound requests
      - outbound delivery path entry at channels API
    - [ ] Permission/security paths (if applicable): validate no implicit permission bypass from nil actor/person data in event assigns.
    - [ ] Edge external API mocks only: adapter edge mocks only.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 2 (`zaq-crk`): Extract `Zaq.Channels.CommunicationBridge`
  - Module placement check: `CommunicationBridge` owns communication-domain callbacks and reusable routing/delegation; `@moduledoc` must clearly separate from internal ZAQ orchestration.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): new module contract tests for provider-key normalization, bridge lookup, and adapter dispatch helpers.
    - [ ] Branch/path coverage:
      - atom and string providers
      - missing bridge/module
      - connection details present/missing
    - [ ] Permission/security paths (if applicable): n/a
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 3 (`zaq-4to`): Refactor `Zaq.Channels.Bridge` into generic incoming hook pipeline
  - Module placement check: `Bridge` retains ZAQ-internal orchestration and hook points (`before_incoming`, `after_incoming`, routing wrapper), bridge implementations override hooks as needed.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): hook pipeline behavior tests across at least jido_chat and email bridge implementations.
    - [ ] Branch/path coverage:
      - default hook pass-through
      - implementation override modifies payload/metadata
      - post-hook error propagation
    - [ ] Permission/security paths (if applicable): event actor and metadata do not widen access scope.
    - [ ] Edge external API mocks only: adapter-facing mocks only.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 4 (`zaq-dyc`): Move runtime routing to `Zaq.Channels.Api` and remove `Zaq.Channels.Router`
  - Module placement check: `Zaq.Channels.Api` is role boundary for NodeRouter events; it should resolve bridge module and invoke communication helpers directly.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): `Channels.Api.handle_event/3` tests for outgoing delivery and runtime operations via direct bridge resolution.
    - [ ] Branch/path coverage:
      - action supported/unsupported
      - no bridge configured
      - bridge callback success/failure
    - [ ] Permission/security paths (if applicable): ensure boundary actions remain explicit (`action`-gated), no free invoke path added.
    - [ ] Edge external API mocks only: bridge callback mocks
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 5 (`zaq-gpj`): Incoming async HopEvent ACK flow through NodeRouter
  - Module placement check: ingress path remains in implementation bridge modules; event dispatch and ACK normalization handled via Bridge/CommunicationBridge helpers.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): inbound adapter payload -> bridge -> NodeRouter async hop -> ACK response assertions.
    - [ ] Branch/path coverage:
      - async hop success returns ACK
      - hop dispatch failure returns error ACK
      - bridge does not perform second NodeRouter loop for response send
    - [ ] Permission/security paths (if applicable): actor/assign propagation is explicit and unchanged.
    - [ ] Edge external API mocks only: adapter listener mocks only.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 6 (`zaq-ohp`): Agent response emitted as async hop and dispatched back to Channels
  - Module placement check: response-event shaping belongs in `Zaq.Agent.Executor`/`Zaq.Agent.Api`; dispatch boundary remains `NodeRouter.dispatch/1`.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): configured agent response creates outbound async hop destined to channels and reaches original adapter bridge path.
    - [ ] Branch/path coverage:
      - default answering path
      - explicit agent selection path
      - missing destination metadata fallback/error
    - [ ] Permission/security paths (if applicable): nil person/actor does not get implicit elevated routing.
    - [ ] Edge external API mocks only: external adapter/API edge only.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 7 (`zaq-7il`): Regression validation and documentation updates
  - Module placement check: tests under channels/agent integration suites; docs in `docs/services/channels.md` and `docs/architecture.md`.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): full message lifecycle matrix for incoming/outgoing across supported bridge types.
    - [ ] Branch/path coverage:
      - legacy route removed assertions (`Router` no longer used)
      - same-adapter reply semantics enforced
      - ACK and response telemetry hooks still emitted (if present)
    - [ ] Permission/security paths (if applicable): n/a unless event permission filters change.
    - [ ] Edge external API mocks only: none beyond existing adapter seams.
  - Coverage target for files touched in this step: `>= 95%`

---

## Decisions Log

Record decisions made during implementation. Future agents need this context.

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Split communication-domain bridge utilities into `CommunicationBridge` while keeping `Bridge` as internal orchestration and hooks | Removes router/bridge duplication without coupling provider-routing concerns into ZAQ-internal pipeline helpers | 2026-05-07 |
| Route incoming and outgoing flow exclusively through `%Zaq.Event{}` + async hop semantics where applicable | Keeps multi-node routing consistent and makes ACK semantics explicit at adapter boundary | 2026-05-07 |
| Remove channel router module after API boundary takes ownership of bridge resolution | Preserves single routing entrypoint (`Channels.Api`) and reduces indirection | 2026-05-07 |

---

## Blockers

List anything blocking progress and who/what can unblock it.

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| Confirm exact async hop payload contract consumed by agent executor/API for response return path | Human + implementation agent | open |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] Integration tests cover key branches/paths
- [ ] Any mocks are limited to edge external API calls
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
