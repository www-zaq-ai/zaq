# Execution Plan

## Plan: Issue 270 - Dynamic Declarations of Tools and AI Agents (Phase 1)

**Date:** 2026-04-18
**Author:** OpenCode (gpt-5.3-codex)
**Status:** `active`
**Related debt:** N/A
**PR(s):** TBD

---

## Goal

Deliver the first phase of issue #270 by enabling BO-managed standalone AI agents that execute through a single standard runtime agent (`Zaq.Agent.Factory`) with runtime parameters passed on `ask/2`. Done means agents can be created/edited in BO, selected explicitly from BO chat, and executed on the Agent node through a single Agent API entrypoint that routes either to unchanged `Pipeline.run/2` (no explicit selection) or to `Zaq.Agent.Executor` (explicit selection), with one long-lived Jido agent server per configured agent id.

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/agent.md`
- [x] `docs/services/system-config.md`
- [x] `docs/WORKFLOW_AGENT.md`
- [x] Existing code reviewed:
  - `lib/zaq/agent/factory.ex`
  - `lib/zaq/agent/api.ex`
  - `lib/zaq/node_router.ex`
  - `lib/zaq/event.ex`
  - `lib/zaq/engine/messages/incoming.ex`
  - `lib/zaq/runtime_deps.ex`
  - `lib/zaq/system.ex`
  - `lib/zaq/system/ai_provider_credential.ex`
  - `lib/zaq/system/llm_config.ex`
  - `lib/zaq_web/router.ex`
  - `lib/zaq_web/components/bo_layout.ex`
  - `lib/zaq_web/live/bo/communication/chat_live.ex`
  - `lib/zaq_web/live/bo/communication/chat_live.html.heex`
  - `lib/zaq_web/live/bo/ai/prompt_templates_live.ex`
  - `test/zaq_web/live/bo/ai/prompt_templates_live_test.exs`

Issue context validated:
- Issue `#270` was reviewed and scoped to Phase 1 only.
- Split from `#247` is honored; "AI Agent as tool" mapping is explicitly out of scope for this plan.

---

## Approach

Use a single event entrypoint on the Agent role and keep routing decisions on the Agent node.

`Zaq.Agent.Api` remains thin and routes execution based on event data:
- No explicit agent selection -> run unchanged `Zaq.Agent.Pipeline.run/2`
- Explicit agent selection -> delegate to `Zaq.Agent.Executor.run/2`

`Zaq.Agent.Executor` owns all custom-agent execution responsibilities for this phase:
- load selected agent config,
- validate model/credential/tools consistency,
- enforce tool whitelist from code registry,
- enforce model capability constraints from `LLMDB`,
- map config into runtime params,
- invoke `Zaq.Agent.Factory.ask/2`.

Custom agents are wired as long-lived Jido processes under `Zaq.Agent.Supervisor` through `Jido.AgentServer`:
- one server per configured agent id,
- stable server naming derived from configured agent id,
- routing in `Zaq.Agent.Executor` resolves target server directly from selected id,
- execution remains asynchronous in runtime tasks while preserving single-flight semantics per configured agent instance.

Selection intent is transported in `event.assigns` (not action name, not request mutation), with `%Zaq.Event{request: %Incoming{...}}` preserved as canonical message payload.

---

## Steps

Break the work into small, independently completable steps. Each step should be
completable in a single PR. Check off as you go.

- [x] Step 1: Add Agent configuration domain under `Zaq.Agent`
  - Add schema/context for BO-managed agent declarations (name, description, job, credential/model, tool keys, conversation toggle, strategy, advanced options, active state).
  - Add migration(s) and indexes for listing/filtering.
  - Keep sovereign flag inferred from provider credential (no duplicated persisted source of truth).

- [x] Step 2: Add code-defined tools registry with capability-aware validation
  - Add `Zaq.Agent.Tools.Registry` as code-level whitelist for allowed tools.
  - Expose descriptors usable by BO forms and runtime validation.
  - Enforce tool/model compatibility using `LLMDB` capabilities (same source used by BO model listing).

- [x] Step 3: Upgrade `Zaq.Agent.Factory` as standard runtime agent
  - Extend `Factory.ask/2` to accept runtime declarations (job/system prompt, model/provider context, enabled tools, strategy, advanced options).
  - Ensure runtime declarations drive behavior for all selected custom agents.
  - Add focused unit tests for runtime overrides and invalid declarations.

- [x] Step 4: Add AgentServer wiring and naming strategy for custom agents
  - Start custom-agent servers under `Zaq.Agent.Supervisor` via `Jido.AgentServer`.
  - Register one long-lived server per configured agent id.
  - Implement deterministic server naming keyed by configured agent id for straightforward executor routing.
  - Add supervision/runtime tests for start, lookup, and restart behavior.

- [x] Step 5: Add `Zaq.Agent.Executor` and route through a single Agent API entrypoint
  - Implement `Zaq.Agent.Executor` to load + validate + map + execute selected agents through `Factory.ask/2` targeting the configured agent server.
  - Keep `Zaq.Agent.Api` thin: branch by `event.assigns["agent_selection"]` and delegate to `Executor` or unchanged `Pipeline`.
  - Keep a single Agent API action/entrypoint for BO chat and related flows.

- [x] Step 6: Add BO Agents management UI
  - Add `/bo/agents` LiveView for list/filter/create/edit (people-directory style split view).
  - Add sidebar entry under AI section in BO layout and route in `router.ex`.
  - Reuse provider/model capability UX patterns from system config screens.

- [x] Step 7: Integrate BO chat explicit agent selection
  - Add agent dropdown in chat top bar, on the same row as Clear chat and to its left.
  - Include explicit selection in event assigns when sending requests.
  - Do not decide execution path in BO; Agent node decides via API routing.

- [ ] Step 8: Validation and documentation
  - Add/extend unit and LiveView tests for schema validation, registry constraints, Agent API routing, executor behavior, and chat selection flow.
  - Run `mix test` through implementation and `mix precommit` before final PR.
  - Update docs (`docs/services/agent.md`, `docs/architecture.md`, and related references) to reflect event contract and execution path.

---

## Decisions Log

Record decisions made during implementation. Future agents need this context.

| Decision | Rationale | Date |
|---|---|---|
| `Zaq.Agent.Factory` is the standard runtime executor for any selected agent | Issue #270 explicitly requires a standard agent fed at runtime via `ask/2` params | 2026-04-18 |
| Keep one Agent API entrypoint/action | Avoid branching API surface; routing must be event-data driven | 2026-04-18 |
| Route decision happens on Agent node | BO must not decide pipeline vs custom-agent execution | 2026-04-18 |
| Explicit selection travels in `event.assigns` | Preserves canonical `%Incoming{}` request shape and keeps intent in transport metadata | 2026-04-18 |
| Introduce `Zaq.Agent.Executor` (no separate adapter module yet) | API stays thin while executor owns load/validate/map/execute concerns with minimal module sprawl | 2026-04-18 |
| Tool registry is code-configured whitelist | Matches issue scope and avoids runtime action declaration complexity in phase 1 | 2026-04-18 |
| Use `LLMDB` capabilities for both UI and backend validation | Single source of truth for model capabilities and consistent enforcement | 2026-04-18 |
| Chat dropdown placement is left of Clear chat on same top bar row | Explicit product requirement from issue planning discussion | 2026-04-18 |
| Use one long-lived AgentServer per configured agent id | Keeps routing straightforward and isolates runtime state per configured agent definition | 2026-04-18 |
| Name/lookup custom-agent servers by configured agent id | Allows `Zaq.Agent.Executor` to route directly without extra discovery indirection | 2026-04-18 |

---

## Blockers

List anything blocking progress and who/what can unblock it.

| Blocker | Owner | Status |
|---|---|---|
| Clarify exact issue #270 phase boundary and acceptance for "conversation enabled" routing semantics | Product/maintainer | open |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
