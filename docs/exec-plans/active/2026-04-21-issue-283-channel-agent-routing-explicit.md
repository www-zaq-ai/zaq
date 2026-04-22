# Execution Plan

## Plan: Issue 283 - Explicit Channel-to-Agent Routing (Phase 1)

**Date:** 2026-04-21
**Author:** OpenCode (gpt-5.3-codex)
**Status:** `active`
**Related debt:** `docs/exec-plans/tech-debt-tracker.md` (channels routing/classifier follow-up)
**PR(s):** TBD

---

## Goal

Deliver phase 1 of issue #283 with explicit routing from communication channel configuration to configured agents, including safe fallback behavior and safe agent deletion constraints. Done means incoming channel messages resolve agent selection by configuration precedence (channel assignment, provider default, global default), routing metadata is passed through `event.assigns["agent_selection"]`, and BO supports deletion from the Edit Agent form with blocking errors when the agent is still referenced anywhere in routing config. If unreferenced, deletion succeeds and runtime processes are cleaned up.

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/conventions.md`
- [x] `docs/elixir.md`
- [x] `docs/services/channels.md`
- [x] `docs/services/agent.md`
- [x] `docs/services/system-config.md`
- [x] `docs/QUALITY_SCORE.md`
- [x] `docs/exec-plans/tech-debt-tracker.md`
- [x] Existing code reviewed:
  - `lib/zaq/channels/channel_config.ex`
  - `lib/zaq/channels/retrieval_channel.ex`
  - `lib/zaq/channels/jido_chat_bridge.ex`
  - `lib/zaq/channels/email_bridge.ex`
  - `lib/zaq/agent.ex`
  - `lib/zaq/agent/api.ex`
  - `lib/zaq/agent/executor.ex`
  - `lib/zaq/system.ex`
  - `lib/zaq/event.ex`
  - `lib/zaq_web/live/bo/communication/channels_live.ex`
  - `lib/zaq_web/live/bo/communication/channels_live.html.heex`
  - `lib/zaq_web/live/bo/communication/notification_imap_live.ex`
  - `lib/zaq_web/live/bo/communication/notification_imap_live.html.heex`
  - `lib/zaq_web/live/bo/system/system_config_live.ex`
  - `lib/zaq_web/live/bo/system/system_config_live.html.heex`
  - `lib/zaq_web/live/bo/ai/agents_live.ex`
  - `lib/zaq_web/live/bo/ai/agents_live.html.heex`
  - `test/zaq/channels/channel_config_test.exs`
  - `test/zaq/channels/retrieval_channel_test.exs`
  - `test/zaq/channels/jido_chat_bridge_test.exs`
  - `test/zaq/channels/email_bridge_test.exs`
  - `test/zaq_web/live/bo/communication/channels_live_test.exs`
  - `test/zaq_web/live/bo/communication/notification_imap_live_test.exs`
  - `test/zaq_web/live/bo/system/system_config_live_test.exs`
  - `test/zaq_web/live/bo/ai/agents_live_test.exs`

Issue context validated:
- Issue `#283` reviewed and constrained to explicit routing first step.
- Tacit/LLM-intent routing remains out of scope for this phase.

---

## Approach

Implement explicit routing as a deterministic resolution layer that enriches event metadata without changing the canonical `%Incoming{}` payload contract. Resolution precedence is:

1. Per-channel assignment (`retrieval_channels.configured_agent_id`, and mailbox/folder equivalent where applicable)
2. Provider/config default agent
3. Global default agent
4. No explicit selection (existing pipeline behavior)

Routing should fail open: if a configured agent is missing/inactive, move to next fallback level instead of hard-failing message processing.

Agent deletion will be upgraded from direct delete to guarded delete:
- Block deletion when the target agent is referenced in routing configuration.
- Return structured and human-readable errors listing all usage locations.
- Allow deletion only when unreferenced, then stop/cleanup runtime server processes.

Testing strategy prioritizes integration tests to cover full flows and branch behavior, with focused unit tests only for pure resolver/helpers.

BO form impact (explicitly in scope for this plan):
- Shared retrieval channel form used by provider routes in `ChannelsLive` (Mattermost and Discord) must include explicit agent assignment controls.
- Email IMAP retrieval form (`NotificationImapLive`) must include mailbox/folder to agent assignment controls.
- System global configuration (`SystemConfigLive`) must include global default agent selection controls.

---

## Steps (TDD - RED/GREEN by step)

Break the work into small, independently completable steps. Each step is executed
as tests-first (failing tests first), then implementation, then verification.

- [x] Step 1 (RED): Add failing integration tests for persistence primitives
  - Add failing tests for channel-level assignment (`retrieval_channels.configured_agent_id`).
  - Add failing tests for provider default assignment storage/retrieval (`channel_configs.settings`).
  - Add failing tests for global default assignment storage/retrieval (`system config` key).
  - Planned test scenarios:
    - `RetrievalChannel` accepts a valid active `configured_agent_id`.
    - `RetrievalChannel` rejects invalid/nonexistent `configured_agent_id` (FK constraint path).
    - Provider default agent id can be set/read/cleared for provider config.
    - Global default agent id can be set/read/cleared.

- [x] Step 2 (GREEN): Implement persistence primitives
  - Add migration for `retrieval_channels.configured_agent_id` (nullable FK + index).
  - Extend `Zaq.Channels.RetrievalChannel` schema/changeset/query helpers.
  - Add provider-default agent helpers to `Zaq.Channels.ChannelConfig`.
  - Add global default agent helpers in `Zaq.System`.
  - Verify Step 1 tests now pass.

- [x] Step 3 (RED): Add failing integration tests for routing resolution precedence
  - Add tests in bridge-centric suites that assert dispatch metadata.
  - Planned test scenarios:
    - Channel assignment wins over provider/global defaults.
    - Provider default applies when channel assignment is missing.
    - Global default applies when provider default is missing.
    - No assignment results in no `agent_selection` assign (legacy pipeline path).
    - Missing/inactive assigned agent falls through to next level.

- [x] Step 4 (GREEN): Implement resolver + bridge integration
  - Integrate resolver in `Zaq.Channels.JidoChatBridge` before `:run_pipeline` dispatch.
  - Integrate resolver in `Zaq.Channels.EmailBridge` for mailbox/folder scoped routing.
  - Preserve existing behavior for unresolved selections.
  - Verify Step 3 tests now pass.

- [x] Step 5 (RED): Add failing BO integration tests for configuration forms
  - Planned test scenarios for communication channel forms:
    - Mattermost form (`ChannelsLive`, shared provider form path) displays agent selector and saves assignment.
    - Discord form (`ChannelsLive`, same shared component flow) displays agent selector and saves assignment.
    - Provider default agent selector in `ChannelsLive` saves and reloads correctly.
  - Planned test scenarios for email IMAP form:
    - `NotificationImapLive` displays mailbox/folder agent assignment controls.
    - Saving IMAP config persists mailbox/folder assignment map and reloads values.
  - Planned test scenarios for global config form:
    - `SystemConfigLive` shows global default agent selector.
    - Saving global config persists and reloads selected default.

- [x] Step 6 (GREEN): Implement BO form updates
  - Update `ChannelsLive` shared form flow (Mattermost/Discord) with channel + provider default agent selectors.
  - Update `NotificationImapLive` form with mailbox/folder assignment controls.
  - Update `SystemConfigLive` with global default agent selector.
  - Verify Step 5 tests now pass.

- [x] Step 7 (RED): Add failing tests for guarded deletion + web UI deletion entrypoint
  - Domain + LiveView tests for guarded deletion behavior.
  - Planned test scenarios:
    - Delete unused agent succeeds and list/detail refreshes.
    - Delete blocked when referenced by retrieval channel assignment.
    - Delete blocked when referenced by provider default.
    - Delete blocked when referenced by IMAP mailbox/folder assignment.
    - Delete blocked when referenced by global default.
    - Error message lists all usage locations (not only first match).
    - BO Edit Agent form has Delete button and uses guarded path.

- [x] Step 8 (GREEN): Implement guarded deletion + Edit Agent Delete button
  - Replace direct `Zaq.Agent.delete_agent/1` behavior with reference checks.
  - Return structured error including usage locations.
  - Ensure successful delete cleans up runtime server process.
  - Add/enable Delete button in BO Edit Agent form and wire error/success UX.
  - Verify Step 7 tests now pass.

- [x] Feedback 1: Confirm unset global default preserves legacy pipeline behavior
  - Added regression tests to assert no `agent_selection` assign is injected when global default is unset and no explicit routing applies.
  - Verified resulting flow continues through existing `Pipeline.run` path.

- [x] Feedback 2: IMAP mailbox assignment UI bound to selected/enabled mailboxes only
  - Assignment controls now render from current selected mailbox list, not all discovered mailboxes.
  - UI updates dynamically when selected mailboxes change.
  - Persisted assignment map now reflects only selected mailboxes.

- [x] Feedback 3: Move global default agent setting to dedicated Global tab
  - Added `Global` tab in system config.
  - Moved global default selector from telemetry panel to Global panel.
  - Renamed empty-option label to `Default Zaq Agent`.

- [x] Refactor: Remove ExDNA-reported duplication in channels and BO parsing helpers
  - Centralized shared bridge mechanics in `Zaq.Channels.Bridge` (pipeline dispatch + selection assign + active-selection resolver).
  - Centralized integer parsing helpers in `Zaq.Utils.ParseUtils` and replaced duplicate local parsers.
  - Extracted repeated IMAP post-save assignment chain into a single helper in `NotificationImapLive`.
  - Verified with `mix ex_dna` (no duplication detected).

- [ ] Step 9: Final verification and hardening
  - Run targeted integration suites first, then full `mix test`.
  - Run `mix precommit`.
  - Confirm branch/error coverage includes happy path and representative failure branches for routing + delete.

---

## Decisions Log

Record decisions made during implementation. Future agents need this context.

| Decision | Rationale | Date |
|---|---|---|
| Explicit routing uses metadata (`event.assigns`) and does not mutate `%Incoming{}` | Keeps boundary contract stable and aligned with existing Agent API routing | 2026-04-21 |
| Routing resolution fails open and falls through on invalid/missing/inactive agents | Avoids message drops and preserves system operability under config drift | 2026-04-21 |
| Agent-selection logic stays bridge-local via `Bridge.resolve_agent_selection/3` optional callback | Preserves bridge ownership of transport-specific routing semantics; avoids cross-bridge policy coupling | 2026-04-21 |
| Unset global default must preserve legacy pipeline fallback behavior | Prevents routing rollout from changing current behavior when global config is intentionally empty | 2026-04-21 |
| IMAP mailbox assignment controls scope to selected mailboxes only | Reduces configuration noise and aligns assignment UX with enabled ingestion scope | 2026-04-21 |
| Global default agent setting moved to dedicated Global tab | Improves discoverability and keeps telemetry panel focused on telemetry-only concerns | 2026-04-21 |
| ExDNA clone remediation should reuse `Bridge` and `ParseUtils` rather than introducing ad-hoc duplicate helpers | Keeps shared behavior centralized and prevents reintroduction of parser and bridge-flow drift | 2026-04-22 |
| Agent deletion is blocked when references exist, with location-rich error reporting | Prevents broken runtime references and gives actionable remediation to users | 2026-04-21 |
| Deletion entrypoint is added to BO Edit Agent form | Matches product requirement to make deletion accessible in web UI | 2026-04-21 |
| Test strategy is integration-first with focused error cases | Maximizes branch coverage of real flows while keeping test suite maintainable | 2026-04-21 |

---

## Blockers

List anything blocking progress and who/what can unblock it.

| Blocker | Owner | Status |
|---|---|---|
| Final product wording for "usage location" display format in BO delete errors | Product/maintainer | open |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Integration tests cover happy path and key error branches for routing and deletion
- [ ] `mix test` passes
- [ ] `mix precommit` passes
- [ ] Relevant docs updated (`docs/services/channels.md`, `docs/services/agent.md`, BO docs as needed)
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed/updated in `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
