# PR #835 communication-boundary handoff

## Goal

Resolve PR #835's findings while preserving independent PR B preparation. The latest approved direction supersedes the earlier history-provider extraction: Channels normalizes communication facts without choosing history policy; Engine owns strategy selection, capture, placement and access interpretation.

## Current State

- Publication authorized by the user to obtain GitHub CI results for PR #835 because local machine contention prevents reliable final gates. This is authorization to commit/push the remediation, not to merge or declare final validation complete. Scoped technical re-review found no new confirmed findings; see `../review/2026-10-04-pr835-remediation-finalization.md`. Latest Chromium retry completed **71 passed / 1 People-access LiveView-readiness timeout**; isolated retry timed out before totals. Fresh coverage first failed application startup on DB checkout, then a four-scheduler retry timed out at 600 seconds with a partial ingestion sandbox-checkout failure. No stale report was used and `mix coverup` was not run. Final current-tree `mix precommit` remains pending. CI must validate the published remediation before dependent PR B integration or final approval; actual publication SHA is recorded in Beadwork/PR after push.

- Latest archive reconciliation correction (`zaq-emb.27.28.5.3`): real Jido webhook regressions first reproduced repeated teardown as `{:ingress_teardown_failed, :already_deleted}` on initial archive and retry. The leaf now resolves the configured bridge and calls existing `stop_runtime/1`, never the enabled/disabled update flow. Final affected **533 tests / 2 properties** and `mix q` (`ERL_FLAGS="+S 1:1"`) passed. The standalone webhook runtime test uses ExUnit without DataCase/Sandbox or a persisted connector; Engine integration verifies initial delete-once, sibling runtime survival, truthful pending stop failure, retry without deletion and unchanged ordinary-disable semantics. Quality-gate corrections reuse existing strict integer parsing and restore alias ordering; no checks were weakened. Review/coverage/final precommit and stable browser validation remain pending. HEAD remains `f634e990cc91f2974c7fda54ace5bb3958a56d63`; no fix SHA or authorized commit/push yet.

- Latest approved ownership follow-up (`zaq-emb.27.28.5.3`): `ChannelConfig` and archive scope/revision/persistence now live in Engine. SMTP/IMAP settings access and runtime projections are shared pure helpers under `Zaq.ConnectorConfig`; provider-local listener/mailbox normalization stays in Channels. No database migration is needed for this namespace move. Legacy Channels persistence callers remain explicitly outside full node isolation.
- Latest affected validation: **2,025 tests / 24 properties, zero failures** across Channels, connector configuration/archive/email, Engine API/data sources/Action schemas, communication BO and provider BO suites. `mix q` passed with `ERL_FLAGS="+S 1:1"` after fixing alias ordering and lifecycle nesting. Existing Chromium channels/system-config runs exercised 64 browser cases: first run 61 passed/3 LLM readiness timeouts, isolated rerun 3 passed; repeat 63 passed/1 capabilities-dialog timeout, isolated rerun 1 passed. No browser assertions were changed; a stable combined browser run is not established. Review/coverage/final precommit remain pending; prior full precommit is not current-tree validation.

- Branch: `feature/issue-768-history-a-integration`; remediation prepared for the authorized CI publication from baseline `f634e990cc91f2974c7fda54ace5bb3958a56d63`. Older validation entries below describe pre-publication snapshots, not a current CI pass.
- There are 38 pre-existing repository stashes, including history-integration stashes. None was applied, created or dropped during this work.
- Neutral-boundary validation: `mix q` passed; affected suite passed **1,536 tests / 26 properties**; existing `channels.spec.js` and `history.spec.js` passed **33 browser cases** across Firefox, WebKit and Chromium.
- The repeated `mix precommit --max-cases 4` passed **10,217 tests / 211 properties / 48 doctests**, zero failures, one skipped and 101 excluded, within the 900-second gate. This run predates the subsequent Action-schema migration and the user's policy typing fix; it is not a final gate against the current tree.
- Latest Action-schema validation: **294 tests / 1 property** passed, including direct schema validation, Exec authorization, workflow contracts, connector operations and BO consumers. `mix q` passed with `ERL_FLAGS="+S 4:4"` after default-scheduler ExDNA checks timed out; no quality-check settings were changed.
- Latest email ownership migration: **405 tests / 2 properties** passed after final code edits, including real Engine settings/API/BO paths and standalone supplied-config Channels runtime tests. `mix q` passed with `ERL_FLAGS="+S 1:1"`; 4/8-scheduler runs hit ExDNA's internal five-second task timeout. No checks were excluded or reconfigured. Earlier full precommit/browser runs predate this migration and must not be claimed against the current tree.
- The first full gate failed in the unchanged telemetry sandbox-failure test; isolated execution and the repeated full gate passed without weakening assertions. This is intermittent evidence, not proof that the flake is fixed.
- New tracking: `zaq-emb.27.28` with `.28.1` → `.28.2` → `.28.3`. Implementation is present, but landing/closure awaits authorized issue-scoped commits. Original remediation issues remain open. Review/coverage and any outstanding human UX approval remain separate gates.
- Approved follow-up `zaq-emb.27.28.5` moves only the touched email settings persistence/runtime seam to Engine; child `.5.1` owns Engine/BO migration and `.5.2` the Repo-free runtime seam. It is not a full Channels-node isolation rollout.
- PR B may continue exact runtime/request identity and busy/finalizing preparation, but dependent integration must use verified, landed contracts. This handoff is not a merge or final-human-approval claim.

## Active files

`M` = tracked modification; `D` = tracked deletion; `U` = untracked, absent from ordinary `git diff`. The inventory includes preserved earlier remediation, not only the neutral-boundary edits.

| File | State | Role |
| --- | --- | --- |
| `docs/services/channels.md` | M | Channels normalization, query, receipt, email and archive contracts |
| `docs/services/engine.md` | M | Engine history interpretation, projection and archive ownership |
| `docs/services/system-config.md` | M | Confidential email settings boundary |
| `docs/exec-plans/active/2026-10-01-handoff-channel-boundaries.md` | M | This handoff; previously tracked and empty |
| `lib/zaq/accounts/bo_actor.ex` | U | Current BO actor validation |
| `lib/zaq/channels/api.ex` | M | Neutral queries/confirmations and confidential settings/archive events |
| `lib/zaq/channels/bridge.ex` | M | Existing connector/bridge resolution |
| `lib/zaq/channels/communication_bridge.ex` | M | Receive-only ingress and optional room query operations |
| `lib/zaq/channels/email_bridge.ex` | M | Neutral email ingress and submitted-envelope receipts |
| `lib/zaq/channels/email_bridge/imap_adapter/parser.ex` | M | Recipient-addressed conversation fact |
| `lib/zaq/channels/history_delivery.ex` | D | History interpretation moved to Engine |
| `lib/zaq/channels/jido_chat_bridge.ex` | M | Consumer-neutral normalization and listener routing |
| `lib/zaq/channels/mattermost_admin.ex` | M | Provider-owned member pagination and exact message retrieval |
| `lib/zaq/engine/actions/save_email_connector.ex` | U | Engine-owned Zoi save Action, moved from Channels |
| `lib/zaq/channels/connector_runtime.ex` | U | Repo-free provider ingress/runtime leaf stages over resolved maps |
| `lib/zaq/engine/channel_config.ex` | U | Moved schema/queries/encryption/default selection; table and IDs unchanged |
| `lib/zaq/connector_config/` | U | Shared pure stored-map, SMTP and IMAP settings access |
| `lib/zaq/channels/delivery_confirmation.ex` | U | Neutral confirmation reporting preserving transport success |
| `lib/zaq/engine/email_connector_settings.ex` | U | Engine snapshots/writes/defaults and confidential resolved-runtime dispatch |
| `lib/zaq/channels/incoming_normalization.ex` | U | Local provider-fact normalization contract |
| `lib/zaq/channels/jido_chat_bridge/incoming.ex` | U | Existing-provider integration selection |
| `lib/zaq/channels/jido_chat_bridge/incoming/discord.ex` | U | Discord evidence normalization and independent DM enrichment |
| `lib/zaq/channels/jido_chat_bridge/incoming/mattermost.ex` | U | Mattermost normalization and neutral query delegation |
| `lib/zaq/channels/jido_chat_bridge/incoming/telegram.ex` | U | Telegram types, timestamps and native chat namespace |
| `lib/zaq/engine/api.ex` | M | Neutral ingress/delivery consumers and archive coordinator dispatch |
| `lib/zaq/engine/channel_history_admin.ex` | M | Batched reads and neutral provider queries |
| `lib/zaq/engine/channel_history_membership.ex` | M | Complete member snapshots interpreted by Engine |
| `lib/zaq/engine/conversations.ex` | M | Policy-selected canonical admission/placement |
| `lib/zaq/engine/conversations/transcript_history.ex` | M | Replay placement conflict protection |
| `lib/zaq/engine/history_ingress.ex` | M | Engine strategy/title derivation and canonical capture |
| `lib/zaq/engine/incoming_message_router.ex` | M | Engine-owned capture eligibility without transport flags |
| `lib/zaq/engine/messages/incoming/routing_context.ex` | M | Neutral conversation facts; no history/title policy fields |
| `lib/zaq/engine/messages/source_identity.ex` | M | Shared opaque scope validation |
| `lib/zaq/engine/workflows/actions/refresh_channel_history_membership.ex` | M | Current BO actor context and existing membership operation |
| `lib/zaq/engine/channel_history_projection.ex` | U | Batched list projection without provider fallback |
| `lib/zaq/engine/connector_lifecycle.ex` | U | Archive scope/revision/locked persistence, watch ordering and cleanup |
| `lib/zaq/engine/history/communication_policy.ex` | U | Provider-independent kind/title interpretation |
| `lib/zaq/engine/history/delivery.ex` | U | Confirmed-delivery association policy |
| `lib/zaq/engine/workflows/actions/archive_channel_connector.ex` | U | Archive coordinator Action |
| `lib/zaq_web/live/bo/communication/channels_live.ex` | M | Archive through Engine boundary |
| `lib/zaq_web/live/bo/communication/email_connector_selection.ex` | M | Confidential event-backed connector snapshots |
| `lib/zaq_web/live/bo/communication/notification_imap_live.ex` | M | Cached form state and Channels-owned saves |
| `lib/zaq_web/live/bo/communication/notification_smtp_live.ex` | M | Cached form state and Channels-owned saves |
| `lib/zaq_web/live/bo/data_sources/provider_live.ex` | M | Archive through Engine coordinator |
| `priv/repo/migrations/20261003000000_widen_message_source_account_key.exs` | U | Guarded widening to text |
| `test/support/e2e/channel_history_fixture.ex` | M | Neutral room facts in existing browser fixture |
| `test/zaq/channels/api_test.exs` | M | Dispatch, confidentiality and neutral confirmation contracts |
| `test/zaq/channels/communication_bridge_test.exs` | M | Receive-only delivery and rejection of policy stamping |
| `test/zaq/channels/email_bridge_test.exs` | M | Neutral email facts and actual receipt audience |
| `test/zaq/channels/jido_chat_bridge_test.exs` | M | Provider normalization and unaddressed ingress regressions |
| `test/zaq/channels/jido_chat_bridge/telegram_reaction_webhook_test.exs` | M | Reaction scope regression |
| `test/zaq/channels/mattermost_admin_test.exs` | M | Neutral room capabilities and unsupported identifiers |
| `test/zaq/channels/mattermost_shared_history_integration_test.exs` | M | Real ingress/member/root integration |
| `test/zaq/channels/telegram_history_delivery_test.exs` | M | Scoped delivery regression |
| `test/zaq/engine/connector_archive_persistence_test.exs` | U | Migrated exact archive stages/retries; concurrent edit and secret-free result coverage |
| `test/zaq/channels/connector_runtime_test.exs` | U | Confidential Repo-free archive runtime event |
| `test/zaq/channels/connector_webhook_runtime_test.exs` | U | Real Jido stop/retry without Repo ownership or provider webhook IO |
| `test/zaq/engine/connector_archive_webhook_test.exs` | U | Real archive/Jido callback sequence, delete-once, failure/retry and ordinary disable |
| `test/zaq/connector_config/settings_test.exs` | U | Shared lookup contracts and top-level-value precedence property |
| `test/zaq/engine/email_connector_settings_test.exs` | U | Exact selection, encrypted save, supplied runtime and pending outcomes |
| `test/zaq/engine/email_connector_settings_api_test.exs` | U | Engine confidentiality/current actor/defaults/Exec dispatch contract |
| `test/zaq/channels/email_runtime_config_test.exs` | U | Real email runtime callback without Repo ownership or stored connectors |
| `test/zaq/channels/incoming_normalization_test.exs` | U | Provider evidence and contradictory-room property |
| `test/zaq/engine/channel_history_admin_test.exs` | M | Batched projection and unsupported refresh |
| `test/zaq/engine/channel_history_membership_test.exs` | M | Neutral input preserving membership/access assertions |
| `test/zaq/engine/conversations/canonical_history_capture_test.exs` | M | Replay, placement and canonical UUID invariants |
| `test/zaq/engine/conversations/transcript_history_test.exs` | M | Placement conflict coverage |
| `test/zaq/engine/history_ingress_test.exs` | M | Real provider/email capture and receipt integration |
| `test/zaq/engine/incoming_message_router_test.exs` | M | Capture eligibility without a Channels flag |
| `test/zaq/engine/messages/incoming/routing_context_test.exs` | M | Typed neutral fact normalization |
| `test/zaq/engine/messages/source_identity_test.exs` | M | Opaque namespace byte contract |
| `test/zaq/engine/scoped_channel_rating_test.exs` | M | Delivery UUID, rating and Telegram isolation invariants |
| `test/zaq/engine/connector_lifecycle_test.exs` | U | Engine archive/watch stage ordering |
| `test/zaq/engine/conversations/source_account_key_migration_test.exs` | U | Widening preserves identities and refuses unsafe narrowing |
| `test/zaq/engine/history/communication_policy_test.exs` | U | Provider-independent selection and rejection of old hints |
| `test/zaq/engine/workflows/actions/connector_action_schema_test.exs` | U | Zoi schemas, required/optional fields, output contracts and Exec validation |
| `test/zaq_web/live/bo/communication/channel_history_live_test.exs` | M | Neutral fixture preserving BO behavior |
| `test/zaq_web/live/bo/communication/notification_imap_live_test.exs` | M | Event-backed BO settings regression |
| `test/zaq_web/live/bo/data_sources/provider_live_test.exs` | M | Archive coordinator regression |

## Changes Made

### Communication boundary and public contracts

- Extend the existing `Bridge.to_internal/2` construction path, not a second history ingress contract. Chat integrations live under `JidoChatBridge.Incoming`; provider-specific Discord enrichment no longer lives in the shared bridge. Listener normalization occurs once and is passed to the addressed/unaddressed handler. Integration selection follows existing provider registration, not replacement transport-adapter identity.
- `Incoming.RoutingContext` replaces `history_kind`/`title_style` with `conversation_type: :one_to_one | :room | :recipient_addressed | nil`. It retains exact connector/source scope, UTC timestamp, identity platform, conversation identity, reply targets and message-local `Audience`. Unknown/contradictory transport facts stay unknown; recipients do not imply complete room membership or grants.
- `History.CommunicationPolicy.kind/1` returns `{:ok, :direct | :channel | :replicated}` or `{:error, :unsupported_history_kind}`. The mappings are one-to-one → Direct, room → Shared, recipient-addressed → Replicated. `title_style/1` derives person/person-subject presentation in Engine. Provider names and legacy transport strategy hints never select policy.
- `CommunicationBridge.receive_message/2` returns `:ok | {:error, reason}`. It sends synchronous Engine `%Event{request: incoming, name: :incoming_message_received, opts: [action: :receive_incoming_message]}`. Engine captures supported facts or returns `{:ok, :received}` for unsupported facts, without generation. Addressed routing no longer sends a `capture_history` flag; Engine decides capture before admission.
- `DeliveryConfirmation.record/3` reports `%{receipt: receipt, outgoing: outgoing}` to Engine action `:record_delivery_confirmation`, retaining only persisted user/assistant IDs from outgoing private metadata. Confirmed receipts use neutral `audience`, `conversation_id`, `source_scope`, `message_id`, and `confirmation: :confirmed`. SMTP audience describes the successfully submitted envelope, not merely inbound header evidence.
- Engine `History.Delivery.capture/2` (also `/3`) alone constructs history confirmation scope and invokes `HistoryIngress.capture_confirmed/1`. Successful association retains `{:ok, receipt}` with `history_capture: :stored`; policy/persistence failure returns bounded `history_capture: :unavailable` without turning delivery into a failed send. If the Engine dispatch itself fails, Channels preserves the receipt with neutral `confirmation_recording: :unavailable`. Pending/failed sends are not confirmations.
- Consumer-neutral `CommunicationBridge.room_capabilities/3`, `room_members/3`, and `fetch_room_message/4` delegate through the configured communication bridge. Provider bridge callbacks are `/2`, `/2`, `/3`, optional for unsupported providers. Events use `:channel_room_capabilities`, `:channel_room_members`, `:channel_room_message` with `%{channel_config_id: id, channel_id: room}` and additionally `message_id` for message retrieval.
- Capabilities return `{:ok, %{members: boolean}}`; complete member results carry `%{complete: true, identity_platform: platform, member_ids: ids}`. Unsupported member operations return `{:error, :unsupported}`. Engine owns refresh policy/grants. Exact message retrieval remains confidential/current-super-admin BO inspection; provider root fallback is detail-only.
- The intermediate uncommitted `HistoryEvidence`, `HistoryProvider`, and history-specific provider configuration were replaced, not retained as a second configuration surface. Old Engine capture actions remain internal compatibility operations; Channels no longer dispatches them for ingress/delivery interpretation.

### Preserved remediation

- `SourceIdentity.valid_scope?/1` owns the nil-or-1–255-byte opaque scope contract. Preserve `SourceIdentity.account_key/3` encoding, canonical message UUIDs, transcript positions/cursors and connector/native-chat isolation.
- Forward migration `20261003000000_widen_message_source_account_key.exs`: `messages.source_account_key` changes from `varchar(255)` to `text`, preserving existing bytes, uniqueness/index semantics and references. No data re-encoding or historical repair. Down migration refuses narrowing while any encoded value exceeds 255 characters, rather than silently truncating.
- Canonical replay rejects changed placement/audience instead of adopting existing placement or backfilling earlier recipients. Existing grant/revocation and recipient-isolation assertions remain intact.
- Email BO persistence now belongs to Engine: confidential Engine `:email_connector_settings` requests use `op: :snapshot`, `:save`, or `:set_default`. `Engine.EmailConnectorSettings.snapshot/1,2`, `save/2`, and `set_default_smtp/1` retain exact connector validation. Save returns `{:ok, %{selected_config_id: id, snapshot: snapshot, runtime: outcome}}`; post-save runtime failure is pending, not a false database rollback. Saves execute via `Jido.Exec` and `Engine.Actions.SaveEmailConnector` with trusted actor context; Zoi schemas are retained.
- Engine decrypts/prepares bounded runtime fields for the exact saved row and dispatches confidential Channels `:sync_provider_runtime` with `%{config: runtime_config}`. Channels applies the supplied map via `CommunicationBridge.sync_provider_runtime/1` and the existing email provider callback, without connector lookup or database-backed actor validation. Enabled IMAP edits restart only that connector; disabling stops it idempotently. An unavailable remote node leaves the database write saved with pending runtime. No settings handler/Action remains in Channels. `ChannelConfig` is now `Zaq.Engine.ChannelConfig`; table, fields, identities and query contracts remain unchanged. Legacy provider-only synchronization, startup and email delivery/attachment DB dependencies remain outside scope.
- `Engine.ConnectorLifecycle.context/3` returns `%{channel_config_id, provider, kind, archived?, revision}`. `archive/2,3` accepts exact connector scope (and optional expected revision), preserves watch ordering, requests teardown, then locks/rechecks revision before persisting. Confidential Channels `:connector_teardown_ingress` carries `%{config: resolved_map}`; `:connector_sync_runtime` carries `%{before_config: before, after_config: after}`. `Channels.ConnectorRuntime.teardown_ingress/2` and `sync_runtime/3` own only transport stages. The old Channels descriptor/archive events and persistence module are removed. Archive result retains ID/status/ingress/runtime/watch_teardown/cleanup; no credentials are returned. Runtime stop retries remain effective even for already-disabled rows; pre-commit mismatch/teardown/revision failures preserve the live row and post-commit remote failures become pending.
- `ConnectorConfig.SmtpSettings.map_get/2`, `ImapSettings.get/2,3` and `Settings` projections are pure/shared. Engine no longer imports provider-local IMAP helpers. The Channels normalization module keeps mailbox/listener functions and a compatibility getter that delegates to shared access. No new Action/tool or storage migration was introduced; existing archive/save Actions and Zoi contracts remain authoritative.
- Engine list projection batches participants/connector/root facts without provider IO; only authorized detail inspection can fetch a provider message.
- Archive runtime reconciliation resolves the configured bridge and invokes existing `stop_runtime/1` directly. It no longer fabricates an enabled before-state or invokes `sync_config_runtime/2`: Jido's ordinary disable transition tears down ingress, which must not run again after Engine's explicit pre-archive stage. Already-stopped runtime success uses the existing bridge normalization; stop failures remain pending and retries perform runtime-only stop. The confidential event/result contract is unchanged. Test runtime collaborator overrides implement `stop_runtime/1`, not the generic update operation. Confidential current BO actor authorization remains on the Engine command.
- Action reuse: extend Bridge/Engine operations; reuse membership Action; add settings/archive Actions around actual operations. Provider parsing is local-only normalization, not a newly exposed agent tool.

## Failed attempts

- The earlier history-specific evidence/provider extraction still left policy in Channels and Discord parsing in the shared bridge. The user's approved neutral-normalization direction replaces that design.
- Using default `ChannelMeta.is_dm == false` to decide listener routing caused pipeline regressions. Routing now uses verified neutral room facts, normalizes once, and retains prior addressed behavior for unsupported/default-only facts.
- Selecting Telegram source namespaces by the configured adapter module broke canonical reaction/rating tests when a numeric-send stub replaced the adapter. Selection now follows provider registration; the actual transport adapter remains available to provider enrichment.
- Legacy test fixtures referenced removed policy fields, events, receipt names and the deleted Channels delivery module. Fixtures now supply factual inputs and assert neutral dispatch; canonical/access/UUID assertions were preserved.
- `mix q` initially reported alias ordering and nested-alias suggestions plus a private `@doc`; these were fixed, followed by clean q and regression runs.
- First full precommit: unchanged `llm_performance_failure_test.exs` expected `DBConnection.OwnershipError`, but a pool checkout exited because a PID was dead. Isolated test passed; repeated complete gate passed without test changes. Do not describe this as a repaired flake.
- Existing E2E passed despite fixture-provider DNS errors logged by refresh/Fresh transport. Passing browser behavior does not demonstrate real external-provider availability.

## Next step

1. **Blocked on user:** review the neutral-boundary changes and authorize issue-scoped commits (or request changes). Do not supply a fabricated fix SHA; update this handoff with actual SHA(s) only after authorization and commits.
2. **Ready:** reconcile PR #835's saved remediation plan/review and Beadwork progress with these superseding contracts. Preserve PR B's independent preparation; integrate dependent work only against landed verified fixes.
3. **Ready after review approval:** perform the separately required coverage/review gates, account for outstanding human UX gates, and rerun final precommit after any resulting code edits. The validations above are regression evidence, not human approval.
4. **Optional:** track the intermittent telemetry sandbox checkout failure separately; no unrelated assertions were changed here.

Do not push directly to main, reset/stash away this work, apply existing stashes, reintroduce Channels strategy/capture flags or history-provider configuration, change encoded source identities/cursors, or broaden incomplete member/header evidence into grants.

### Session log

- 2026-10-04: implemented the approved neutral Channels / Engine-policy boundary over the existing uncommitted remediation; passed q, affected tests, existing three-browser regressions and repeated full precommit. HEAD unchanged; commit/review/coverage authorization remains outstanding.
- 2026-10-04 follow-up (`zaq-emb.27.28.4`): converted input/output schemas in SaveEmailConnector, ArchiveChannelConnector and RefreshChannelHistoryMembership to Zoi objects. Preserved required/optional fields, nil/new/exact connector selection, wrapped domain-error results, map/count outputs and actor authorization. Schema tests first failed on the Nimble schema representation and then passed; affected 294-test/1-property suite and reduced-scheduler q passed. No commit, staging or policy-typing edits; final precommit must be repeated after review against the updated tree.
- 2026-10-04 email ownership follow-up (`zaq-emb.27.28.5`): moved settings and save Action/tests from Channels to Engine; retargeted BO events; extended existing runtime sync with a supplied-config confidential path. Added current-user/default/Exec tests, unreachable-node save preservation, decrypted runtime versus encrypted storage assertions, and real callback restart/sibling/disable tests without Repo ownership. Initial fixtures needed live BO password state and required SMTP placeholders; the Exec transport observer was changed to an allowed Mox expectation because execution occurs in a task. Final 405-test/2-property run and single-scheduler q passed. Preserved existing staging and user work; no commit/push. No new UI or feature E2E authored; earlier browser/full gates remain historical until rerun.
