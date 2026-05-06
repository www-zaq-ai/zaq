# Execution Plan

## Plan: Issue 300 - MCP Administration in BO with Agent-managed MCP runtime

**Date:** 2026-04-23
**Author:** OpenCode (gpt-5.3-codex)
**Status:** `completed`
**Related debt:** N/A
**PR(s):** TBD

---

## Goal

Deliver issue #300 by adding MCP administration to BO (`/bo/system-config`) while keeping MCP runtime logic in the Agent namespace. Done means admins can list/filter/paginate MCPs, add/edit custom MCPs, see hardcoded predefined MCPs as disabled until enabled, enable predefined entries into the MCP DB table, and run an MCP tools connectivity test through an Agent API action that uses `Jido.MCP.Actions.ListTools`. OAuth is explicitly planned as a follow-up phase with a reusable architecture and storage model.

---

## Context

Docs read before planning:

- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/system-config.md`
- [x] `docs/services/agent.md`
- [x] `docs/phoenix.md`
- [x] `docs/exec-plans/active/`
- [x] `docs/exec-plans/tech-debt-tracker.md`
- [x] `docs/QUALITY_SCORE.md`

Existing code reviewed:

- `lib/zaq/system.ex`
- `lib/zaq/system/ai_provider_credential.ex`
- `lib/zaq_web/live/bo/system/system_config_live.ex`
- `lib/zaq_web/live/bo/system/system_config_live.html.heex`
- `lib/zaq_web/components/core_components.ex`
- `lib/zaq/node_router.ex`
- `lib/zaq/agent/api.ex`
- `test/zaq/system/ai_provider_credential_test.exs`
- `test/zaq_web/live/bo/system/system_config_live_test.exs`
- `test/e2e/specs/system_config.spec.js`
- `deps/jido_mcp/lib/jido_mcp/actions/list_tools.ex`
- `deps/jido_mcp/lib/jido_mcp/endpoint.ex`
- `deps/jido_mcp/lib/jido_mcp/config.ex`
- `deps/jido_mcp/lib/jido_mcp/client_pool.ex`
- `deps/anubis_mcp/lib/anubis/transport/stdio.ex`
- `deps/anubis_mcp/lib/anubis/transport/streamable_http.ex`

Key constraints from issue + clarifications:

- BO UI stays in BO namespace; MCP runtime logic stays in Agent namespace.
- No `predefined` or `icon` DB fields; predefined/icon metadata comes from hardcoded declarations.
- Enabling a predefined MCP creates an MCP row in DB.
- Add one JSON `settings` field for forward compatibility.
- New cross-role calls must use `NodeRouter.dispatch/2` (not `call/4`).
- Agent role receives these calls through `Zaq.Agent.Api` with explicit action handling.
- Predefined MCPs are displayed as disabled by default.

---

## Approach

Use a two-layer model:

1) **Persisted MCP endpoints** in a new MCP table for all configured/enabled runtime entries.
2) **Hardcoded predefined catalog** declared as a map inside `Zaq.Agent.MCP` (id, label, icon, defaults, `editable` flag) merged at BO read-time with persisted entries, so missing predefined entries render as disabled placeholders.

Runtime mutation path:

- BO LiveView validates and saves through context.
- BO dispatches event with `NodeRouter.dispatch(event, runtime)` to Agent API action.
- `Zaq.Agent.Api` delegates to Agent MCP service module for endpoint registration/unregistration + connectivity test.

Security model:

- Secret maps (`secret_env`, `secret_headers`) are encrypted value-by-value at write-time using `Zaq.Types.EncryptedString.encrypt/1`.
- UI uses revealable secret inputs and surfaces field-level encryption errors.

Pagination/filtering follows existing BO patterns (`PeopleLive`/`Agent.filter_agents`) for consistency and testability.

---

## Steps

- [x] Step 1: Add Agent MCP domain model and migration (PR 1)
  - Tests to add before implementation:
    - `test/zaq/agent/mcp_test.exs` (DataCase integration): create/update validation for local/remote MCPs, defaults, enum validation, conditional required fields.
    - Migration-focused integration assertions (via context): unique `predefined_id` behavior, default `settings` + `timeout_ms`.
  - Branches/paths validated:
    - local vs remote validation branches.
    - enabled vs disabled status validation.
    - valid/invalid timeout branches.
    - uniqueness + default-path persistence.
  - Mocking plan:
    - No mocks (all internal boundaries + DB real).
  - Coverage target for touched files:
    - >=95% for `lib/zaq/agent/mcp*.ex`, `lib/zaq/agent/mcp/endpoint.ex`, and migration file branch coverage through integration tests.

- [x] Step 2: Add Agent MCP service + predefined catalog map in `Zaq.Agent.MCP` (PR 1)
  - Tests to add before implementation:
    - Extend `test/zaq/agent/mcp_test.exs` with integration tests for predefined catalog merge behavior.
    - Tests for `editable` policy enforcement on enabled predefined MCP rows.
  - Branches/paths validated:
    - predefined missing from DB shows disabled placeholder.
    - enabling predefined creates persisted row from defaults.
    - predefined `editable: false` blocks edit path.
    - predefined `editable: true` allows edit path.
    - custom MCP CRUD unaffected.
  - Mocking plan:
    - No mocks (real context + DB).
  - Coverage target for touched files:
    - >=95% for all modified `lib/zaq/agent/mcp*.ex` files.

- [x] Step 3: Add secret key/value encryption behavior (key plaintext, value encrypted) (PR 1)
  - Tests to add before implementation:
    - Extend `test/zaq/agent/mcp_test.exs` with integration tests asserting:
      - secret keys remain visible plaintext.
      - secret values stored encrypted.
      - blank update preserves existing encrypted value.
      - encryption key missing/invalid produces field errors.
    - Extend `test/zaq_web/live/bo/system/system_config_live_test.exs` to verify secret key visibility in edit form without exposing values.
  - Branches/paths validated:
    - encrypt success path.
    - missing key path.
    - invalid key path.
    - preserve-on-blank update path.
  - Mocking plan:
    - No mocks (encryption + DB real).
  - Coverage target for touched files:
    - >=95% for modified schema/context/liveview files touching secret handling.

- [x] Step 4: Add Agent runtime sync and Agent API action wired through `NodeRouter.dispatch/2` (PR 2)
  - Tests to add before implementation:
    - `test/zaq/agent/mcp/runtime_test.exs` (integration with supervised runtime process, edge API mocked only).
    - Extend `test/zaq/agent/api_test.exs` for new MCP action routing.
    - Extend `test/zaq/node_router_test.exs` for MCP event dispatch-to-agent path.
  - Branches/paths validated:
    - register endpoint success/failure.
    - unregister endpoint success/unknown endpoint.
    - enable/disable sync behavior.
    - unsupported action and malformed event payload handling.
  - Mocking plan:
    - Mock only edge external MCP calls (`Jido.MCP.register_endpoint/1`, `Jido.MCP.unregister_endpoint/1`, endpoint status/list-tools edge calls as needed).
    - Keep NodeRouter, Agent API, and internal modules real.
  - Coverage target for touched files:
    - >=95% for `lib/zaq/agent/api.ex`, `lib/zaq/agent/mcp/runtime.ex`, and any routing glue touched.

- [x] Step 5: Add MCP tab and CRUD UX in BO System Config LiveView (PR 3)
  - Tests to add before implementation:
    - Extend `test/zaq_web/live/bo/system/system_config_live_test.exs` for MCP tab navigation, list rendering, filters, pagination, modal flows, conditional local/remote fields, predefined enable flow, editable lock behavior.
  - Branches/paths validated:
    - tab selection + invalid tab fallback.
    - list empty/non-empty.
    - filter combinations and pagination boundaries.
    - add/edit/save error branches.
    - predefined disabled row vs enabled persisted row behavior.
  - Mocking plan:
    - No internal mocks in LiveView tests.
    - External MCP network behavior remains mocked only in Agent runtime tests.
  - Coverage target for touched files:
    - >=95% for modified `system_config_live.ex` and related render/component logic touched.

- [x] Step 6: Add MCP `Test` button flow (UI -> `NodeRouter.dispatch/2` -> Agent API -> `Zaq.Agent.MCP.Runtime` -> `Jido.MCP.Actions.ListTools`) (PR 3)
  - Tests to add before implementation:
    - Extend `test/zaq_web/live/bo/system/system_config_live_test.exs` for Test button success/error rendering.
    - Extend `test/zaq/agent/mcp/runtime_test.exs` for list-tools invocation contract and normalized response.
    - Extend `test/zaq/agent/api_test.exs` for MCP test action delegation.
  - Branches/paths validated:
    - test success branch.
    - test transport/protocol error branch.
    - test invalid/disabled endpoint branch.
    - test timeout/error detail propagation branch.
  - Mocking plan:
    - Mock only edge `Jido.MCP.Actions.ListTools` execution path / MCP remote edge.
    - Keep NodeRouter + Agent API + Runtime orchestration real.
  - Coverage target for touched files:
    - >=95% for all files modified for test-action plumbing and UI response handling.

- [x] Step 7: Coverage hardening + regression suite (PR 3)
  - Tests to add before implementation:
    - Add branch-closing integration tests for any touched file under 95%.
    - Extend `test/e2e/specs/system_config.spec.js` with MCP admin happy path + MCP test failure UX path.
  - Branches/paths validated:
    - any remaining uncovered negative/edge branches in touched files.
    - end-to-end MCP BO flow integrity.
  - Mocking plan:
    - E2E mocks only at true external boundaries (if required by environment); internal app boundaries remain real.
  - Coverage target for touched files:
    - >=95% for every added/modified file in this plan; document exceptions if any.

- [x] Step 8: Documentation + final validation (PR 3)
  - Tests to add before implementation:
    - No new tests expected for docs-only changes; if code changes are introduced during this step, add tests first for those changes.
  - Branches/paths validated:
    - N/A for docs-only edits.
  - Mocking plan:
    - N/A for docs-only edits.
  - Coverage target for touched files:
    - Maintain >=95% for all code files touched in Steps 1-7.

- [ ] Step 9 (Deferred/Future): OAuth reusable flow for remote MCP (separate issue/PR series)
  - Build reusable OAuth module (not MCP-only), proposed namespace:
    - `Zaq.Auth.OAuth` (or `Zaq.Integrations.OAuth`) with provider-agnostic callbacks.
  - No new dependency required initially: use existing `Req` + internal PKCE/state/token-refresh implementation.
  - Storage model: dedicated `oauth_credentials` table, encrypted secret/token fields, and explicit ownership linkage (`owner_type` + `owner_id` or typed owner references) so credentials attach to the target resource/person and can be reused by other stacks.
  - MCP remote auth flow to include dynamic client registration (RFC 7591) and token refresh handling.
  - Add UI wiring in a later phase: `Authenticate` action, callback handling, status/expiry indicators.

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Keep MCP persistence/runtime in Agent namespace; BO handles only presentation/orchestration | Matches role boundaries and user clarification | 2026-04-23 |
| Predefined metadata is hardcoded, not persisted as dedicated fields | Avoid schema coupling for display concerns; allows default-disabled catalog entries | 2026-04-23 |
| Add `settings` JSON field for forward compatibility | Enables non-breaking extension for provider-specific options | 2026-04-23 |
| New cross-role MCP operations use `NodeRouter.dispatch/2` only | `call/4` is deprecated and explicitly disallowed for new work | 2026-04-23 |
| Agent API gets explicit MCP admin action(s) | Keep role boundary explicit and avoid direct module calls from BO | 2026-04-23 |
| Predefined MCP declarations live in `Zaq.Agent.MCP` map and include `editable` policy | Keeps predefined behavior centralized and avoids unnecessary module sprawl | 2026-04-23 |
| Secret key names remain plaintext while secret values are encrypted | Allows safe key visibility in edit UX without exposing secret data | 2026-04-23 |
| MCP test execution is routed via `NodeRouter.dispatch/2` to `Zaq.Agent.Api` action `:mcp_test_list_tools` | Preserves BO->Agent boundary and keeps runtime behavior in Agent namespace | 2026-04-23 |
| BO MCP form uses line-based key/value editors (`key=value`) and JSON settings textarea | Keeps implementation simple while supporting multi-value args/env/header workflows in this phase | 2026-04-23 |
| OAuth is deferred but planned as reusable subsystem | Needed across stacks; prevents MCP-specific one-off implementation | 2026-04-23 |
| OAuth implementation should start with existing `Req` stack (no extra deps by default) | No OAuth support found in current jido/anubis deps; prefer minimal dependency surface | 2026-04-23 |
| MCP endpoint names are unique | Prevent operator confusion and align BO validation with DB integrity | 2026-04-24 |
| Decrypt failures in runtime secret maps are logged and ignored | Keeps runtime resilient while surfacing key-rotation/corruption diagnostics | 2026-04-24 |
| MCP test uses `tools/list` (not endpoint liveness) | `endpoint_status` only checks process health, not auth/protocol correctness | 2026-04-24 |
| BO action buttons use reusable loading hook/component | Standardizes disable/spinner/reset UX for pending click actions | 2026-04-24 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Final predefined MCP catalog (ids, names, icons, locked defaults) | Product/maintainer | mitigated (current hardcoded catalog in place) |
| Confirm ownership model for future oauth credentials (`resource/person` relation shape) | Product/architecture | deferred to Step 9 |

---

## Definition of Done

- [x] All non-deferred steps above completed (Steps 1-8)
- [x] Step-level test definitions were written before implementation for every implementation step
- [x] Required tests were implemented and passing
- [x] Coverage for every touched file is >= 95%
- [x] Any file below 95% has exact rationale + follow-up documented in Decisions Log and PR
- [x] `mix precommit` passes
- [x] Relevant docs updated
- [x] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [x] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [x] Plan moved to `docs/exec-plans/completed/`
- [x] Deferred OAuth step tracked as a dedicated follow-up issue/plan
