# Execution Plan

## Plan: Issue 311 - Persist Tool Call Metadata from Telemetry

**Date:** 2026-05-02
**Author:** OpenCode (gpt-5.3-codex)
**Status:** `completed`
**Related debt:** N/A
**PR(s):** TBD

---

## Goal

Implement end-to-end capture and persistence of per-tool execution details (timestamp, params, response, response_time_ms) for agent answers, using Jido telemetry as the canonical source. Done means tool traces are captured in `Zaq.Agent.JidoTelemetryBridge`, delivered back to the active execution flow, attached to assistant message metadata, and persisted into conversation history for all channels that already use `persist_from_incoming`.

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/agent.md`
- [x] `docs/services/engine.md`
- [x] `docs/services/channels.md`
- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/exec-plans/PLAN_STRATEGY.md`
- [x] Existing code reviewed:
  - `lib/zaq/agent/jido_telemetry_bridge.ex`
  - `lib/zaq/agent/factory.ex`
  - `lib/zaq/agent/executor.ex`
  - `lib/zaq/engine/messages/outgoing.ex`
  - `lib/zaq/engine/conversations.ex`
  - `lib/zaq/channels/bridge.ex`
  - `lib/zaq/channels/jido_chat_bridge.ex`
  - `lib/zaq_web/live/bo/communication/chat_live.ex`
  - `test/zaq/agent/jido_telemetry_bridge_test.exs`

### Infrastructure Audit

- [x] Existing entry points checked (Factory, Executor, builders, helpers):
  - `Factory.ask_with_config/4` + `await/2` already own request lifecycle and status context setup.
  - `Executor.run/2` already normalizes result metadata and is the right join point for adding tool traces.
  - `Outgoing.from_pipeline_result/2` already merges result map into outbound metadata.
  - `Conversations.persist_from_incoming/2` already writes assistant records and is the correct persistence boundary.
- [x] `@moduledoc` read for every module that will receive new code:
  - `Zaq.Agent.JidoTelemetryBridge`, `Zaq.Agent.Executor`, `Zaq.Agent.Factory`, `Zaq.Engine.Conversations`
- [x] No parallel code path being created where an existing one can be extended: confirmed.
- [x] Provider/credential/URL logic confirmed to stay in its designated module: N/A for this change (no provider config changes).

---

## Approach

Use telemetry events (`tool.start`, `tool.execute.start`, `tool.complete`/`stop`, `tool.error`/`exception`) as the source of truth, aggregate per-request tool traces in `Zaq.Agent.JidoTelemetryBridge`, and emit a compact finalized payload back to the requester process when the request completes. `Executor.run/2` will consume that payload (best-effort, bounded wait), attach `tool_calls` into the existing result metadata map, and rely on the current `Outgoing -> persist_from_incoming` flow to store it in message metadata.

This avoids introducing new persistence APIs, avoids direct DB writes from telemetry handlers, and aligns with existing BO metadata display pattern (`"tool_calls"` key).

---

## Steps

- [ ] Step 1: Define and implement telemetry aggregation contract in `Zaq.Agent.JidoTelemetryBridge`
  - Module placement check: `Zaq.Agent.JidoTelemetryBridge` owns Jido telemetry handling; `@moduledoc` covers this responsibility.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): event-sequence tests that feed tool start/stop/error and request completion to bridge and assert emitted trace payload.
    - [ ] Branch/path coverage:
      - tool success path (`start -> stop/complete`)
      - tool failure path (`start -> error/exception/timeout`)
      - missing `tool_call_id` path (ignored or safely normalized)
      - multi-tool within one request
      - out-of-order or duplicate events resilience
    - [ ] Permission/security paths (if applicable): none (no permission scope changes)
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 2: Propagate finalized traces back to execution and attach to result metadata
  - Module placement check: `Zaq.Agent.Executor` owns execution result normalization; `Zaq.Agent.Factory` already carries request context and is the proper place for request correlation context if needed.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): `Executor.run/2` receives telemetry trace message and includes `tool_calls` in output metadata.
    - [ ] Branch/path coverage:
      - traces available within wait window
      - traces absent/late (fallback to empty list)
      - request failure still returns stable result shape
    - [ ] Permission/security paths (if applicable): none
    - [ ] Edge external API mocks only: use existing injected module seams (`factory_module`, etc.) only as needed
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 3: Persist tool traces in conversation message metadata using existing persistence path
  - Module placement check: `Zaq.Engine.Conversations.persist_from_incoming/2` owns assistant message persistence; `@moduledoc` covers this.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): persisted assistant message includes metadata key `"tool_calls"` with captured entries.
    - [ ] Branch/path coverage:
      - tool_calls present
      - tool_calls absent (metadata remains valid map)
      - existing assistant fields (tokens/confidence/latency) unchanged
    - [ ] Permission/security paths (if applicable): none
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 4: Documentation and verification
  - Module placement check: service docs (`docs/services/agent.md`, optionally `docs/services/engine.md`) are the proper ownership for behavior documentation.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): none
    - [ ] Branch/path coverage: none
    - [ ] Permission/security paths (if applicable): none
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%` for code files; docs excluded

---

## Decisions Log

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Use Jido telemetry as canonical tool-trace source, not final request payload introspection | Telemetry gives consistent per-tool lifecycle timing and call-level correlation via `tool_call_id`; avoids provider/result-shape coupling | 2026-05-02 |
| Return traces to execution flow via process message on request completion | Keeps telemetry write-free (no DB writes), preserves existing `Executor -> Outgoing -> Conversations` persistence path | 2026-05-02 |
| Persist under assistant message `metadata["tool_calls"]` | Matches existing BO chat rendering convention and avoids schema churn | 2026-05-02 |

---

## Blockers

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| Confirm exact telemetry metadata keys for full params/response payload across all tool events | Implementation | open |

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
