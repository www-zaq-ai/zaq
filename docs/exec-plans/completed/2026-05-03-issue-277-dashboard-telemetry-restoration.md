# Execution Plan

## Plan: Issue 277 - Restore Dashboard Telemetry Mappings

**Date:** 2026-05-03
**Author:** OpenCode (gpt-5.3-codex)
**Status:** `completed`
**Related debt:** N/A
**PR(s):** TBD

---

## Goal

Restore dashboard telemetry accuracy by wiring LLM API call counting to Jido `llm.start`, wiring token usage to Jido `request.complete` (input/output/total split preserved), removing duplicate token emitters, and standardizing channel attribution (including Mattermost and email) through centralized `Incoming` telemetry helpers so charts populate consistently across all communication channels.

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/agent.md`
- [x] `docs/services/engine.md`
- [x] `docs/services/channels.md`
- [x] `docs/services/telemetry.md`
- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/exec-plans/PLAN_STRATEGY.md`
- [x] Existing code reviewed:
  - `lib/zaq/agent/jido_telemetry_bridge.ex`
  - `lib/zaq/agent/executor.ex`
  - `lib/zaq/agent/pipeline.ex`
  - `lib/zaq/agent/api.ex`
  - `lib/zaq/engine/telemetry.ex`
  - `lib/zaq/engine/telemetry/dashboard_data.ex`
  - `lib/zaq/engine/messages/incoming.ex`
  - `lib/zaq/channels/jido_chat_bridge.ex`
  - `lib/zaq/channels/email_bridge.ex`
  - `lib/zaq_web/controllers/agent_controller.ex`
  - `lib/zaq_web/live/bo/communication/chat_live.ex`
  - `test/zaq/agent/jido_telemetry_bridge_test.exs`
  - `test/zaq/engine/telemetry/dashboard_data_test.exs`

### Infrastructure Audit

- [x] Existing entry points checked (Factory, Executor, builders, helpers):
  - `Factory`/Jido telemetry path already emits lifecycle events; extend bridge instead of adding parallel collectors.
  - `Executor.run/2` currently emits `qa.tokens.*`; this is the duplicate source to remove once bridge emits from Jido completion events.
  - `DashboardData` already computes chart payloads; update metric source there instead of creating alternate dashboard loaders.
  - `Incoming` currently has no constructor/helper; add centralized helper here for telemetry dimensions consumed by pipeline callers.
- [x] `@moduledoc` read for every module that will receive new code:
  - `Zaq.Agent.JidoTelemetryBridge`
  - `Zaq.Agent.Executor`
  - `Zaq.Engine.Messages.Incoming`
  - `Zaq.Engine.Telemetry.DashboardData`
  - Channel bridge modules that pass pipeline options
- [x] No parallel code path being created where an existing one can be extended: confirmed.
- [x] Provider/credential/URL logic confirmed to stay in its designated module: confirmed (`ProviderSpec`/`Factory` untouched).

---

## Approach

Use Jido telemetry as canonical source for both API-call counting and token usage while preserving existing token metric keys. Record `qa.llm.call.count` on every `[:jido, :ai, :llm, :start]` event; record `qa.tokens.prompt`, `qa.tokens.completion`, and `qa.tokens.total` on `[:jido, :ai, :request, :complete]` from event measurements (`input_tokens`, `output_tokens`, `total_tokens`). Remove token recording from `Executor` to prevent double counting.

For channel attribution, add `Incoming.new/1` and `Incoming.telemetry_dimensions/2` to derive normalized telemetry dimensions (`channel_type`, `channel_config_id`, etc.) from canonical inbound payloads. Use this helper in BO/API and retrieval channel bridge paths so `qa.message.count` and related metrics are consistently labeled for Mattermost, email, and other providers.

For dashboard continuity, change LLM API Calls chart to read `qa.llm.call.count` and include backward-compatible fallback to legacy proxy behavior where needed so historical points still render.

---

## Current-to-Target Metric Mapping

- `LLM API Calls`
  - Current: dashboard counts `qa.tokens.total` point count (proxy at request granularity).
  - Target: dashboard counts `qa.llm.call.count` emitted on each `jido.ai.llm.start` (true per-call granularity).
- `Input tokens`
  - Current: `Executor.record_success_telemetry/2` emits `qa.tokens.prompt`.
  - Target: `JidoTelemetryBridge` emits `qa.tokens.prompt` from `request.complete.measurements.input_tokens`.
- `Output tokens`
  - Current: `Executor.record_success_telemetry/2` emits `qa.tokens.completion`.
  - Target: `JidoTelemetryBridge` emits `qa.tokens.completion` from `request.complete.measurements.output_tokens`.
- `Total tokens`
  - Current: `Executor.record_success_telemetry/2` emits `qa.tokens.total`.
  - Target: `JidoTelemetryBridge` emits `qa.tokens.total` from `request.complete.measurements.total_tokens`.
- `Questions per channel`
  - Current: grouped by `channel_type`, but many non-BO paths do not provide consistent dimensions.
  - Target: all ingress paths compute dimensions via `Incoming.telemetry_dimensions/2` so Mattermost/email/other channels are consistently attributed.

---

## Steps

- [ ] Step 1: Add canonical Jido telemetry metric emission in `Zaq.Agent.JidoTelemetryBridge`
  - Module placement check: Bridge owns Jido telemetry handling; this responsibility fits `@moduledoc`.
  - Temporary code? no
  - Functional specifications covered with associated files to edit/add:
    - `lib/zaq/agent/jido_telemetry_bridge.ex` emits business metrics from Jido events.
    - Reads token counts strictly from `measurements` (`input_tokens`, `output_tokens`, `total_tokens`) with no metadata fallback.
  - Tests to add before implementation:
    - [ ] Integration test(s):
      - `llm.start` emits exactly one `qa.llm.call.count` point per event.
      - `request.complete` emits `qa.tokens.prompt/completion/total` with expected values from sample payload shape.
    - [ ] Branch/path coverage:
      - measurements present
      - measurements missing (no token metrics emitted)
      - non-integer/invalid token fields ignored
      - events without request context do not crash
    - [ ] Permission/security paths (if applicable): none
    - [ ] Edge external API mocks only: none
  - Documentation updates for this step:
    - `docs/services/telemetry.md` metric-source mapping update.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 2: Remove duplicate token emitters and keep non-token telemetry stable
  - Module placement check: `Executor` owns execution-level business telemetry for answer lifecycle; token source moves to bridge.
  - Temporary code? no
  - Functional specifications covered with associated files to edit/add:
    - `lib/zaq/agent/executor.ex` no longer records `qa.tokens.*` to avoid double counting.
    - Preserve `qa.answer.count`, latency, confidence, and error metrics behavior.
  - Tests to add before implementation:
    - [ ] Integration test(s): execution success path still records answer/latency/confidence metrics; token metrics no longer emitted from executor.
    - [ ] Branch/path coverage:
      - success path with tokens present
      - success path without tokens
      - error path unchanged
    - [ ] Permission/security paths (if applicable): none
    - [ ] Edge external API mocks only: none
  - Documentation updates for this step:
    - `docs/services/agent.md` telemetry ownership notes.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 3: Centralize telemetry dimensions in `Incoming` and adopt in callers
  - Module placement check: `Incoming` is canonical ingress payload; deriving telemetry dimensions from it matches module ownership.
  - Temporary code? no
  - Functional specifications covered with associated files to edit/add:
    - `lib/zaq/engine/messages/incoming.ex`:
      - add `new/1` constructor
      - add private telemetry-dimension derivation helper(s) invoked automatically by `new/1`
      - normalize provider/channel values for telemetry use
      - inject computed telemetry dimensions into `incoming.metadata` in a stable internal key used by pipeline callers
      - update module docs to declare `new/1` as the canonical way to build `%Incoming{}`
    - Update ingress call sites to use helper-provided dimensions:
      - `lib/zaq/channels/jido_chat_bridge.ex`
      - `lib/zaq/channels/email_bridge.ex`
      - `lib/zaq_web/controllers/agent_controller.ex`
      - `lib/zaq_web/live/bo/communication/chat_live.ex`
      - any other `%Incoming{}` builders that feed pipeline telemetry
  - Tests to add before implementation:
    - [ ] Integration test(s):
      - Mattermost path records `qa.message.count` with `channel_type="mattermost"`.
      - Email path records `qa.message.count` with `channel_type="email:imap"`.
      - BO/API keep expected labels.
    - [ ] Branch/path coverage:
      - provider atom vs string
      - missing channel config id defaults to `"unknown"`
      - fallback channel type for unknown/invalid provider
      - pre-populated metadata telemetry dimensions are preserved/merged consistently
    - [ ] Permission/security paths (if applicable): none
    - [ ] Edge external API mocks only: none
  - Documentation updates for this step:
    - `docs/services/channels.md` and/or `docs/services/engine.md` for telemetry dimension derivation ownership.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 4: Update dashboard source mapping with backward compatibility
  - Module placement check: `DashboardData` owns chart data assembly.
  - Temporary code? no
  - Functional specifications covered with associated files to edit/add:
    - `lib/zaq/engine/telemetry/dashboard_data.ex` LLM API Calls chart reads `qa.llm.call.count`.
    - Backward compatibility: fallback to legacy proxy (`qa.tokens.total` point count) when call-count data is absent in selected range.
    - Token usage charts keep existing keys unchanged.
  - Tests to add before implementation:
    - [ ] Integration test(s):
      - chart uses `qa.llm.call.count` when present.
      - chart falls back to legacy `qa.tokens.total` point count when new metric absent.
    - [ ] Branch/path coverage:
      - only new metric present
      - only legacy metric present
      - mixed data in same window
      - empty dataset
    - [ ] Permission/security paths (if applicable): none
    - [ ] Edge external API mocks only: none
  - Documentation updates for this step:
    - `docs/services/telemetry.md` chart metric source and migration note.
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 5: Full validation and closeout
  - Module placement check: validation only.
  - Temporary code? no
  - Tests to add before implementation: none (execution step)
  - Branch/path coverage: enforce coverage gates for all touched files.
  - Permission/security paths (if applicable): confirm no permission-path behavior changed.
  - Edge external API mocks only: none
  - Commands:
    - `mix test` targeted suites for touched modules
    - `mix precommit`
  - Coverage target for files touched in this step: `>= 95%`

---

## Decisions Log

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Add `qa.llm.call.count` emitted at `jido.ai.llm.start` | Required to count multi-call requests correctly; legacy proxy via `qa.tokens.total` cannot represent per-call reality | 2026-05-03 |
| Keep token metric keys unchanged (`qa.tokens.prompt/completion/total`) | Preserve existing dashboard queries and historical continuity | 2026-05-03 |
| Move token emission ownership from `Executor` to Jido bridge | Single canonical source avoids double counting and aligns with event semantics | 2026-05-03 |
| Add `Incoming` telemetry helper API | Prevents repeated ad-hoc dimension maps and fixes cross-channel attribution drift | 2026-05-03 |

---

## Blockers

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| None identified | N/A | closed |

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
