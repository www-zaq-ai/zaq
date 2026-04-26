# Execution Plan

## Plan: Issue 301 - Agent MCP assignment in BO with hot runtime sync via NodeRouter.dispatch/2

**Date:** 2026-04-24
**Author:** OpenCode (gpt-5.3-codex)
**Status:** `active`
**Related debt:** N/A
**PR(s):** TBD

---

## Goal

Deliver issue #301 by adding MCP assignment management to BO Agents (`/bo/agents`) and wiring all runtime-impacting updates through `NodeRouter.dispatch/2` to `Zaq.Agent.Api`. Done means BO users can add/remove MCPs on agents, see MCP status in the agent form, and have both agent MCP-selection edits and MCP endpoint edits reflected in running agent processes via in-place hot runtime patching without process swap management.

---

## Context

Docs read before planning:

- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/agent.md`
- [x] `docs/services/system-config.md`
- [x] `docs/exec-plans/PLAN_STRATEGY.md`
- [x] `docs/exec-plans/PLAN_TEMPLATE.md`
- [x] `docs/exec-plans/active/`
- [x] `docs/exec-plans/tech-debt-tracker.md`
- [x] `docs/QUALITY_SCORE.md`

Existing code reviewed:

- `lib/zaq_web/live/bo/ai/agents_live.ex`
- `lib/zaq_web/live/bo/ai/agents_live.html.heex`
- `lib/zaq/agent.ex`
- `lib/zaq/agent/configured_agent.ex`
- `lib/zaq/agent/server_manager.ex`
- `lib/zaq/agent/factory.ex`
- `lib/zaq/agent/api.ex`
- `lib/zaq/agent/mcp.ex`
- `lib/zaq/agent/mcp/endpoint.ex`
- `lib/zaq/agent/mcp/runtime.ex`
- `lib/zaq/node_router.ex`
- `lib/zaq_web/live/bo/system/system_config_live.ex`
- `test/zaq_web/live/bo/ai/agents_live_test.exs`
- `test/zaq/agent/api_test.exs`
- `test/zaq/node_router_test.exs`
- `test/zaq/agent/server_manager_test.exs`
- `test/zaq/agent/factory_test.exs`
- `test/zaq/agent/mcp/runtime_test.exs`
- `deps/jido_ai/lib/jido_ai.ex`
- `deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex`
- `deps/jido_mcp/lib/jido_mcp.ex`
- `deps/jido_mcp/lib/jido_mcp/client_pool.ex`
- `deps/jido_mcp/lib/jido_mcp/plugins/mcp.ex`
- `deps/jido_mcp/lib/jido_mcp/jido_ai/plugins/mcp_ai.ex`
- `deps/jido_mcp/lib/jido_mcp/jido_ai/actions/sync_tools_to_agent.ex`
- `deps/jido_mcp/lib/jido_mcp/jido_ai/actions/unsync_tools_from_agent.ex`

Key constraints from issue + clarifications:

- BO must use `NodeRouter.dispatch/2` for all runtime-impacting agent/MCP operations.
- Runtime strategy decision belongs to Agent node executor-side logic.
- MCP updates should use generic `:mcp_endpoint_updated` event contract.
- MCP assignment supports predefined and custom MCP endpoints.
- Runtime endpoint ID mapping uses deterministic atom naming `:"mcp_#{id}"`.
- Runtime endpoint ID mapping must be implemented in existing `Zaq.Agent.MCP.Runtime`.
- Atom safeguards required: reject growth at >=85% atom-limit usage and cap MCP endpoints to 2000.
- For this issue, prefer hot runtime patch path and skip swap-management scope.

---

## Approach

Implement an event-first runtime update pipeline:

1) BO LiveViews dispatch agent/MCP mutations as `%Zaq.Event{}` via `NodeRouter.dispatch/2`.
2) `Zaq.Agent.Api` handles explicit actions and delegates to executor-side orchestration.
3) Executor computes update strategy (`:no_runtime_change`, `:hot_runtime_patch`, `:drain_and_stop`) from field diffs.
4) For `:hot_runtime_patch`, mutate the running process in place:
   - agent MCP selection edits: sync/unsync MCP tools on running server.
   - MCP endpoint edits: refresh/re-register endpoint + re-sync impacted agents.
5) Runtime endpoint IDs are generated centrally in `Zaq.Agent.MCP.Runtime` as `:"mcp_#{id}"`.
6) Atom safety is enforced before endpoint registration and surfaced as BO/API errors.

Update strategy matrix for this plan:

- `:no_runtime_change`: name/description/display-only updates.
- `:hot_runtime_patch`: model, credential, enabled tools, enabled MCP endpoint IDs, and MCP endpoint config edits (type/status/url/command/args/headers/environments/settings).
- `:drain_and_stop`: deactivation/deletion paths.

`drain_and_swap` is explicitly out-of-scope for issue #301 unless a blocker is discovered that makes hot patching impossible.

---

## Steps

- [ ] Step 1: Add event contracts and dispatch-only BO wiring for agent/MCP runtime-impacting flows
  - Functional specifications covered with associated files to edit/add:
    - BO agent create/update/delete runtime-impacting flows dispatch `%Zaq.Event{}` through `NodeRouter.dispatch/2` instead of direct context calls in `lib/zaq_web/live/bo/ai/agents_live.ex`.
    - BO MCP mutation flows (save/enable/update) dispatch to Agent role through `NodeRouter.dispatch/2` in `lib/zaq_web/live/bo/system/system_config_live.ex`.
    - Event payloads include action-specific request maps expected by Agent API handlers.
  - Tests to add before implementation:
    - Extend `test/zaq_web/live/bo/ai/agents_live_test.exs` to assert BO agent create/update/delete go through dispatch path (behavioral assertions + branch coverage around API error feedback).
    - Extend `test/zaq_web/live/bo/system/system_config_live_test.exs` for MCP save/enable/update dispatch path.
  - Branches/paths validated:
    - dispatch success path.
    - dispatch unsupported action path.
    - dispatch invalid payload path.
    - dispatch rpc failure/error payload path surfaced in BO.
  - Mocking plan:
    - Mock only boundary response shape where needed (NodeRouter runtime function hooks).
    - Keep internal LiveView behavior real.
  - Documentations to update for both code and AGENTS.md related descriptions:
    - `docs/services/agent.md` (BO -> Agent boundary for runtime-impacting updates).
    - `docs/services/system-config.md` (MCP update dispatch behavior).
    - `AGENTS.md` only if agent entrypoint map or mandatory rules wording changes.
  - Coverage target for touched files:
    - >=95% for modified BO LiveView modules and corresponding tests.

- [ ] Step 2: Extend Agent API actions for `configured_agent_updated`, `configured_agent_deleted`, and generic `mcp_endpoint_updated`
  - Functional specifications covered with associated files to edit/add:
    - Add explicit Agent API action handlers in `lib/zaq/agent/api.ex` for `:configured_agent_updated`, `:configured_agent_deleted`, and `:mcp_endpoint_updated`.
    - Ensure action routing contract remains event-first with `%Zaq.Event{}` response envelopes.
    - Add/extend executor delegate module(s) under `lib/zaq/agent/` for strategy computation entrypoints.
  - Tests to add before implementation:
    - Extend `test/zaq/agent/api_test.exs` for each new action success/error/invalid-request branch.
    - Extend `test/zaq/node_router_test.exs` dispatch-action routing coverage for new actions.
  - Branches/paths validated:
    - action routing success.
    - malformed payload.
    - unsupported action.
  - Mocking plan:
    - Mock only executor delegate module at API boundary.
  - Documentations to update for both code and AGENTS.md related descriptions:
    - `docs/services/agent.md` (new Agent API actions and runtime orchestration entrypoints).
    - `docs/architecture.md` if event contracts section requires update.
    - `AGENTS.md` only if architectural routing rules are changed.
  - Coverage target for touched files:
    - >=95% for `lib/zaq/agent/api.ex` and routing glue touched.

- [ ] Step 3: Add agent MCP assignment persistence + validation in Agent domain
  - Functional specifications covered with associated files to edit/add:
    - Add persisted MCP assignment field(s) to configured agents (migration + schema in `priv/repo/migrations/*` and `lib/zaq/agent/configured_agent.ex`).
    - Add normalization/validation in `lib/zaq/agent.ex` for assignment shape, uniqueness, and endpoint existence policy.
    - Expose assignment-aware change/create/update flows used by BO and runtime orchestrator.
  - Tests to add before implementation:
    - Add migration + schema tests for `enabled_mcp_endpoint_ids` in `configured_agents`.
    - Extend `test/zaq/agent/configured_agent_test.exs` and `test/zaq/agent/agent_test.exs` for normalization, uniqueness, invalid IDs, and missing endpoint validation.
  - Branches/paths validated:
    - empty/default list.
    - add/remove IDs.
    - non-list coercion.
    - unknown/disabled endpoint handling policy.
  - Mocking plan:
    - No mocks (DB/context real).
  - Documentations to update for both code and AGENTS.md related descriptions:
    - `docs/services/agent.md` (configured agent schema now includes MCP assignment field).
    - `docs/project.md` or domain docs if schema map/reference tables are listed.
    - `AGENTS.md` only if doc map must point to a new dedicated reference.
  - Coverage target for touched files:
    - >=95% for modified schema/context/migration-related code.

- [ ] Step 4: Implement runtime endpoint-id mapping and safeguards in `Zaq.Agent.MCP.Runtime`
  - Functional specifications covered with associated files to edit/add:
    - Implement deterministic runtime endpoint-id mapping in `lib/zaq/agent/mcp/runtime.ex` using `:"mcp_#{id}"` and reverse parsing helpers.
    - Enforce atom safety guard (`>=85%` atom usage threshold) in runtime registration path.
    - Enforce MCP endpoint cap (`2000`) before admitting new runtime endpoint registrations.
  - Tests to add before implementation:
    - Extend `test/zaq/agent/mcp/runtime_test.exs` for `:"mcp_#{id}"` conversion (to/from) and invalid formats.
    - Add tests for atom budget threshold rejection and endpoint-count cap rejection.
  - Branches/paths validated:
    - valid id mapping.
    - invalid id mapping parse errors.
    - atom usage under threshold.
    - atom usage above threshold.
    - endpoint cap reached.
  - Mocking plan:
    - Mock only system-info reads via injectable function options where needed.
  - Documentations to update for both code and AGENTS.md related descriptions:
    - `docs/services/agent.md` (runtime endpoint ID + safety guard behavior).
    - `docs/services/system-config.md` (user-visible failure cases when caps/guards trigger).
    - `AGENTS.md` only if secret/safety handling map needs explicit note.
  - Coverage target for touched files:
    - >=95% for modified `lib/zaq/agent/mcp/runtime.ex` and guard helpers touched.

- [ ] Step 5: Build executor-side hot runtime patch orchestration for agent MCP selection changes
  - Functional specifications covered with associated files to edit/add:
    - Add executor orchestration that computes MCP assignment diff and applies in-place sync/unsync on live agent server.
    - Route orchestration through Agent API action handlers without direct BO runtime calls.
    - Persist and expose per-agent runtime patch result envelopes for BO feedback handling.
  - Tests to add before implementation:
    - Add executor integration tests to verify selection-diff behavior (sync added, unsync removed).
    - Extend `test/zaq/agent/server_manager_test.exs` if routing/ensure interactions change.
  - Branches/paths validated:
    - no-op diff.
    - add-only diff.
    - remove-only diff.
    - mixed diff.
    - sync/unsync partial failures and error propagation.
  - Mocking plan:
    - Mock only edge MCP sync/unsync calls.
    - Keep executor/domain/runtime wiring real.
  - Documentations to update for both code and AGENTS.md related descriptions:
    - `docs/services/agent.md` (executor strategy matrix and hot patch orchestration).
    - `docs/architecture.md` (runtime update sequence for configured agents).
    - `AGENTS.md` only if the role-boundary rule wording needs clarification.
  - Coverage target for touched files:
    - >=95% for executor orchestration files touched.

- [ ] Step 6: Build generic MCP endpoint update orchestration (`:mcp_endpoint_updated`) to patch impacted agents in place
  - Functional specifications covered with associated files to edit/add:
    - Add impacted-agent discovery path (based on persisted MCP assignments) to executor-side MCP update orchestration.
    - Apply endpoint refresh/re-register and per-agent resync as in-place runtime patch actions.
    - Return aggregate result payloads for BO-friendly success/failure reporting.
  - Tests to add before implementation:
    - Add/extend tests to validate impacted-agent discovery from MCP assignments.
    - Validate endpoint refresh/re-register + agent re-sync orchestration branches.
  - Branches/paths validated:
    - endpoint update with no impacted agents.
    - impacted agents hot-patched successfully.
    - endpoint refresh failure.
    - per-agent sync failure with aggregate reporting.
  - Mocking plan:
    - Mock only external MCP edge operations (client pool/register/refresh/list-tools where needed).
  - Documentations to update for both code and AGENTS.md related descriptions:
    - `docs/services/system-config.md` (generic MCP endpoint update runtime implications).
    - `docs/services/agent.md` (how `:mcp_endpoint_updated` is handled).
    - `AGENTS.md` only if documentation map or mandatory rule pointers change.
  - Coverage target for touched files:
    - >=95% for touched MCP orchestration modules.

- [ ] Step 7: Update BO Agents UI to include MCP management section above tools management
  - Functional specifications covered with associated files to edit/add:
    - Add MCP management section above enabled-tools in `lib/zaq_web/live/bo/ai/agents_live.html.heex`.
    - Add MCP picker/add/remove event handlers and selected-state persistence in `lib/zaq_web/live/bo/ai/agents_live.ex`.
    - Show MCP status dot in selected MCP list (green enabled, red disabled) and picker restricted to enabled MCPs.
  - Tests to add before implementation:
    - Extend `test/zaq_web/live/bo/ai/agents_live_test.exs` for:
      - section ordering (MCP above tools),
      - add/remove MCP behavior,
      - only enabled MCPs listed in picker,
      - status dot rendering (green enabled / red disabled).
  - Branches/paths validated:
    - empty MCP list.
    - selected/unselected sets.
    - disabled MCP visibility in selected list.
    - form validation with mixed tool + MCP updates.
  - Mocking plan:
    - No internal mocks in LiveView tests.
  - Documentations to update for both code and AGENTS.md related descriptions:
    - `docs/services/agent.md` (BO agents UI behavior with MCP assignments).
    - `docs/phoenix.md` only if reusable BO UX pattern guidance is updated.
    - `AGENTS.md` only if BO UI guidance mapping changes.
  - Coverage target for touched files:
    - >=95% for modified agents LiveView modules/templates.

- [ ] Step 8: Validation + documentation closeout
  - Functional specifications covered with associated files to edit/add:
    - Ensure final runtime contracts are consistent across BO LiveViews, Agent API, and executor orchestration.
    - Ensure all direct BO calls touching Agent/MCP runtime logic are replaced with `NodeRouter.dispatch/2`.
    - Ensure release-ready behavior for happy path and error path messaging in BO.
  - Tests to add before implementation:
    - Add branch-closing tests for any touched file under 95%.
  - Branches/paths validated:
    - all remaining negative/error paths discovered in steps 1-7.
  - Mocking plan:
    - Keep mocks limited to external edge API calls.
  - Documentations to update for both code and AGENTS.md related descriptions:
    - Update all touched service docs in this plan (`docs/services/agent.md`, `docs/services/system-config.md`, and any architecture references).
    - Update `docs/QUALITY_SCORE.md` if the domain grade meaningfully changes.
    - Update `AGENTS.md` only if required navigation/rule text changed from implementation.
  - Coverage target for touched files:
    - >=95% for every added/modified code file in this plan.

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Use `NodeRouter.dispatch/2` for all new BO -> Agent runtime-impacting calls | Enforces architecture boundary and multi-node correctness | 2026-04-24 |
| Keep MCP update event generic as `:mcp_endpoint_updated` | Single contract; strategy selection based on field diffs in Agent node | 2026-04-24 |
| Support MCP assignment for predefined and custom endpoints | Product requirement | 2026-04-24 |
| Runtime endpoint ID mapping is `:"mcp_#{id}"` and implemented inside `Zaq.Agent.MCP.Runtime` | Deterministic and centralized conversion policy | 2026-04-24 |
| Enforce atom safety guard at >=85% atom usage and endpoint count cap 2000 | Prevent unbounded atom-table growth risk | 2026-04-24 |
| Prefer hot runtime patch; skip drain-and-swap for issue #301 scope | Existing jido_ai/jido_mcp APIs support in-place mutation for MCP/tools paths | 2026-04-24 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Confirm whether agent model/credential hot patch can stay in-place for all providers without restart fallback in this issue scope | Maintainer/architecture | open |

---

## Definition of Done

- [ ] All non-deferred steps above completed
- [ ] Step-level functional specifications were written before implementation
- [ ] Step-level test definitions were written before implementation for every implementation step
- [ ] Required tests were implemented and passing
- [ ] Coverage for every touched file is >= 95%
- [ ] Any file below 95% has exact rationale + follow-up documented in Decisions Log and PR
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
