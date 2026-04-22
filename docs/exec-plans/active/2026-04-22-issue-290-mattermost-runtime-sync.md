# Execution Plan

## Plan: Mattermost Bridge-Owned Runtime Sync for Issue 290

**Date:** 2026-04-22  
**Author:** OpenCode  
**Status:** `active`  
**Related debt:** none identified  
**PR(s):** TBD

---

## Goal

Fix issue `#290` by making Mattermost runtime reconfiguration bridge-owned behind the existing router entrypoints, while also fixing the BO edit modal so an existing bot token is visible/editable like other secret-backed fields. Done means Mattermost config edits and retrieval-channel subscription edits apply the correct runtime action (`refresh`, listener restart, or full restart) while BO continues to call `Zaq.Channels.Router`, and the Mattermost edit form correctly loads the existing token.

---

## Context

Docs reviewed:

- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/project.md`
- [x] `docs/services/channels.md`
- [x] `docs/services/system-config.md`
- [x] `docs/QUALITY_SCORE.md`
- [x] `docs/exec-plans/tech-debt-tracker.md`
- [x] `docs/exec-plans/PLAN_TEMPLATE.md`

Existing code reviewed:

- [x] `lib/zaq/channels/jido_chat_bridge.ex`
- [x] `lib/zaq/channels/jido_chat_bridge/state.ex`
- [x] `lib/zaq/channels/supervisor.ex`
- [x] `lib/zaq/channels/retrieval_channel.ex`
- [x] `lib/zaq_web/live/bo/communication/channels_live.ex`
- [x] `lib/zaq_web/live/bo/communication/channels_live.html.heex`
- [x] `lib/zaq/types/encrypted_string.ex`
- [x] `lib/zaq_web/live/bo/communication/notification_imap_live.ex`
- [x] `lib/zaq_web/live/bo/communication/notification_imap_live.html.heex`
- [x] `lib/zaq_web/live/bo/communication/notification_smtp_live.html.heex`
- [x] `test/zaq/channels/jido_chat_bridge_test.exs`
- [x] `test/zaq_web/live/bo/communication/channels_live_test.exs`
- [x] `test/zaq/channels/router_test.exs`

Relevant findings:

- `Router.sync_config_runtime/2` and `Router.sync_provider_runtime/1` are the correct BO-facing entrypoints and should remain the gateway that delegates to provider bridges.
- For an already-running Mattermost runtime, `JidoChatBridge.ensure_runtime_started/3` currently refreshes `State` only and does not rebuild listener processes.
- Listener channel scope is derived at startup from `load_active_channel_ids/1`, so retrieval channel changes are not applied by state refresh alone.
- The Mattermost BO modal currently blanks the token field in edit mode, unlike IMAP/SMTP secret fields.

---

## Approach

Keep lifecycle policy at the bridge edge, but preserve the router as the only BO-facing API.

Do not change `Zaq.Channels.ChannelConfig`. Keep BO routed through `Zaq.Channels.Router`, and add bridge-owned sync entrypoints in `Zaq.Channels.JidoChatBridge` that the router can delegate to. The bridge classifies config changes and chooses the smallest correct action:

- no-op
- state refresh only
- listener-side restart
- full runtime restart

For issue `#290`, the bridge should initially support:

- refresh-only for handler/chat metadata changes
- full restart as the safe implementation for listener-affecting or runtime-affecting changes unless a listener-only restart path can be added cleanly in the same scope

In parallel, fix the Mattermost edit modal so the existing token is shown in the form and uses the same reveal/hide pattern already used by IMAP/SMTP.

Why this approach:

- keeps BO provider-agnostic by routing through `Zaq.Channels.Router`
- keeps provider-specific runtime policy out of `ChannelsLive`
- matches the service boundary in `docs/services/channels.md`
- avoids broad persistence-layer changes
- allows a conservative implementation first, with future refinement from full restart to listener-only restart if needed

---

## Runtime Policy

Define the actions as follows.

`refresh`
- Keep the runtime and listener processes alive.
- Refresh only the bridge `State` config/chat state.

`listener_restart`
- Keep the bridge state process if practical.
- Recreate listener children so new listener opts and `channel_ids` take effect.
- Preferred for retrieval-channel membership or ingress-listener option changes.
- If the current supervisor model makes this expensive, full restart is an acceptable first implementation.

`full_restart`
- Stop and restart the whole bridge runtime for the config.
- Recreate both state and listener children.
- Use for `url`, `token`, or other startup-bound transport/runtime inputs.

Initial Mattermost classification:

`refresh`
- `settings["jido_chat"]["bot_name"]`
- other handler-only settings that do not affect listener child specs or startup connection details

`listener_restart`
- retrieval channel add/remove/toggle
- active channel list changes from `RetrievalChannel`
- ingress/listener settings under Mattermost adapter config, if any are persisted in config

`full_restart`
- `url`
- `token`
- any other config field consumed directly by startup/runtime construction

---

## Steps

- [ ] Step 1: Add a formal exec plan file in `docs/exec-plans/active/` using this content and get human confirmation on the runtime policy table if needed.
- [ ] Step 2: Add bridge-owned sync API in `Zaq.Channels.JidoChatBridge` for config-to-config sync and provider-config sync after retrieval-channel mutations.
- [ ] Step 3: Implement Mattermost change classification inside `JidoChatBridge`, with tests proving refresh-only versus restart behavior.
- [ ] Step 4: Implement the minimal correct restart mechanism in `JidoChatBridge`.
Line item:
If listener-only restart can be added cleanly, use it for channel-subscription changes.
If not, use full restart for listener-affecting changes and document that fallback in the decisions log.
- [ ] Step 5: Keep `channels_live.ex` router-only by calling `Zaq.Channels.Router` after:
Line item:
successful config save via `sync_config_runtime/2`
successful retrieval channel add via `sync_provider_runtime/1`
successful retrieval channel toggle via `sync_provider_runtime/1`
successful retrieval channel removal via `sync_provider_runtime/1`
- [ ] Step 6: Fix the Mattermost token field in `channels_live.html.heex` so edit mode loads the existing token and uses the same eye-toggle UX as IMAP/SMTP.
- [ ] Step 7: Add or update tests in `test/zaq_web/live/bo/communication/channels_live_test.exs` for:
Line item:
existing token visible in edit modal
blank token still preserves existing secret on save
config save triggers bridge sync
retrieval channel add/toggle/remove trigger bridge sync
- [ ] Step 8: Add or update tests in `test/zaq/channels/jido_chat_bridge_test.exs` for:
Line item:
refresh-only config mutation does not restart unnecessarily
retrieval-channel changes force listener/runtime reload
`url` or `token` changes force full restart
listener options after restart reflect updated active channel ids
- [ ] Step 9: Run validation:
Line item:
targeted tests for changed modules
full `mix test`
`mix precommit`
- [ ] Step 10: Update docs if implementation introduces a new bridge sync API or changes runtime semantics in a way future agents need to know.
Line item:
likely `docs/services/channels.md`
possibly decisions log only if behavior is internal and unchanged externally

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Runtime sync policy belongs in `JidoChatBridge`, routed through `Router` | Provider bridges own lifecycle/runtime semantics, but BO should only call the router gateway | 2026-04-22 |
| Do not modify `ChannelConfig` for issue `#290` | The bug is not in persistence or validation; it is in runtime/application of changes | 2026-04-22 |
| `ChannelsLive` must not call bridge modules directly | BO should stay provider-agnostic and use existing router entrypoints | 2026-04-22 |
| Use full restart for startup-bound fields like `url` and `token` | Safest minimal behavior with current architecture | 2026-04-22 |
| Prefer listener-only restart for subscription/listener changes, but allow full restart fallback initially | Current runtime model does not yet expose a first-class listener-only restart path | 2026-04-22 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Need to confirm whether a listener-only restart is worth implementing now or deferred behind a full-restart fallback | Human + implementer | Open |

---

## Definition of Done

- [ ] Mattermost config save applies bridge-owned sync behavior through `Zaq.Channels.Router`
- [ ] Retrieval channel add/toggle/remove applies bridge-owned sync behavior
- [ ] Existing bot token is visible/editable in the Mattermost edit modal
- [ ] Blank token submission still preserves existing token
- [ ] Bridge tests cover refresh versus restart policy
- [ ] LiveView tests cover BO regression paths
- [ ] `mix test` passes
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Plan moved to `docs/exec-plans/completed/`
