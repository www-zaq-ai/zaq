# Integrating a Communication Channel

Use this guide when adding a communication provider or extending an existing
adapter. It gives developers and coding agents an implementation sequence, review
questions, and a reusable acceptance checklist.

Domain contracts remain in [Channels](../services/channels.md),
[Engine](../services/engine.md), and the
[message lifecycle guide](../services/message-lifecycle.md). Follow those owners
when details change; this guide organizes the work without replacing their APIs.

## 1. Define the integration before implementing it

Record the following in the feature's Beadwork issue. Follow the
[agent workflow](../WORKFLOW_AGENT.md) for planning and delivery.

| Decision | What to establish |
| --- | --- |
| Transport | Webhook, polling, gateway, linked device, or another supported runtime; authentication and deployment prerequisites. |
| Account scope | What identifies a saved connector, its receiving account, and its provider tenant/server. Assume two configurations from the start. |
| Identity | Stable native user ID, authority, profile lookup, phone/email evidence, and behavior when profile fields are absent. |
| Conversations | Evidence for direct messages, rooms, recipient-addressed messages, threads, replies, and unsupported room types. |
| Reply policy | Agent assignment, explicit None, mentions, self messages, imported history, and passive capture. |
| Capabilities | Send, edit, typing, reactions, profiles, membership, message lookup, media, logout, and pairing. Mark each supported, unsupported, or deferred. |
| Persistence | Non-secret settings, encrypted credentials, temporary state, restart guarantees, and logout/delete effects. |
| Acceptance | Required journeys below, provider-specific expectations, known limitations, and test ownership. |

Read the relevant adapter behavior and existing implementations before choosing a
design. Inspect module responsibilities and actual callers. A similar provider is
a useful reference, but copying its whole implementation also copies its assumptions.

- [ ] List affected operations and record reuse/extend/new/local-only decisions
  under the [Action reuse gate](../action-reuse.md).
- [ ] Identify upstream adapter changes and host changes separately, with
  dependencies between their issues.
- [ ] Define unsupported behavior explicitly. Missing capability or incomplete
  identity evidence must not silently enable a broader path.
- [ ] Plan new feature E2E scenarios early under the
  [UX/UI approval gate](../testing-approach.md#feature-e2e-approval-gate).

## 2. Assign each responsibility to its owner

| Responsibility | Owner and review question |
| --- | --- |
| Provider protocol, parsing, native identifiers, QR expiry, connection/storage mechanics, transport formatting | Provider adapter/package. Can this work without knowledge of ZAQ schemas, People, or Agent internals? |
| Reusable adapter capability contracts and normalized transport envelopes | Shared adapter library. Can another provider implement the same contract without arguments specific to the first provider? |
| Adapter selection, trusted host options, canonical message conversion, delivery and runtime orchestration | Channels bridge. Does it delegate provider mechanics through the existing adapter boundary? |
| Child startup, registration, shutdown and recovery | Shared Channels runtime plus adapter-supplied child specs. Does it reuse the existing supervisor path? |
| Connector persistence, routing, history strategy, execution admission and credential authorization | Engine and its existing domain operations. Does transport report facts instead of selecting product policy? |
| Native identity ownership, Person discovery and connector links | People/Accounts. Does another connector reuse the appropriate Person while retaining its own channel link? |
| Configuration forms, pairing presentation, status and operator feedback | BO and shared components. Do cross-service operations use supported events through `NodeRouter.dispatch/1`? |

Read [system configuration](../services/system-config.md) before working on secrets
and [DESIGN.md](../../DESIGN.md) before BO implementation.

### Common coupling pitfalls

| Pitfall | Design check |
| --- | --- |
| Provider pairing, storage and lifecycle mechanics implemented in ZAQ | Keep provider mechanics upstream; expose the smallest host persistence/authorization boundary. |
| Separate startup plumbing for one provider | Extend the established lifecycle through shared child-spec and listener paths. |
| Bespoke authentication and storage callbacks | Reuse shared request contracts, the trusted sink and existing authorized operations. |
| Provider-specific runtime assumptions in generic modules | Keep opaque connection identity and delivery options opaque in generic code; verify with another provider. |
| Person identity tied unnecessarily to one connector | Distinguish native identity authority from connector-specific routing and credentials. |
| Inline quoted-message content used as trusted context | Resolve original content through authorized canonical history; provider quote text must not become a parallel prompt/history pipeline. |
| Account choices stored in global provider registration | Keep defaults and reply policy in persisted connector settings and shared projections; registration configuration describes wiring. |

## 3. Build and validate one complete path at a time

### A. Register the adapter and establish configuration ownership

Start with [provider registration](../../config/config.exs),
[ProviderCatalog](../../lib/zaq/channels/provider_catalog.ex),
[shared settings](../../lib/zaq/connector_config/settings.ex), and
[Engine ChannelConfig](../../lib/zaq/engine/channel_config.ex).
Inspect the [shared adapter extension contracts](../services/channels.md#shared-adapter-extension-contracts).

- [ ] Register the provider through the existing bridge/adapter mechanism.
- [ ] For webhook providers, use the existing
  [webhook ingress](../services/channels.md#webhook-ingress) and adapter verification
  contract. Bind the endpoint to its connector and validate provider authentication
  before admitting messages; body-supplied account or actor IDs are not authority.
- [ ] Persist configurable account choices per connector. Reuse shared settings
  projections for defaults and merging; preserve explicit values, including false.
- [ ] Reject malformed explicit settings; distinguish an omitted value from an
  invalid one. Define behavior for existing connectors with missing keys.
- [ ] Keep credential references separate from encrypted secret material. Reuse
  existing credential/grant operations before proposing a schema or secret type.
- [ ] Require an exact connector for account-sensitive operations. Ambiguous
  provider-only resolution must not choose the first enabled account.
- [ ] Verify the adapter dependency exposes the required contracts and is available
  to CI and releases; a developer's sibling checkout is insufficient release evidence.

### B. Complete authentication and lifecycle

Use the [bridge lifecycle](../services/channels.md#runtime-lifecycle) and
[supervisor contract](../services/channels.md#supervisor).
For interactive authentication, inspect the
[linked-device flow](../services/channels.md#linked-device-integration).

- [ ] Define provisional → authenticated → saved → runtime-ready transitions,
  cancellation, expiry, retry, and partial failure outcomes.
- [ ] Reauthorize sensitive commands using the trusted operator and exact binding;
  public ingress must reject private authentication/storage requests.
- [ ] Keep storage callbacks out of serialized message handling when outbound
  transport can call storage synchronously. Exercise this path for deadlocks.
- [ ] Make repeated confirmation safe. A saved account whose runtime failed to
  start must be reported as saved/pending, with recovery that does not create a duplicate.
- [ ] Correlate lifecycle updates with the connector and current source/attempt.
  An old QR, response, or process exit must not overwrite newer state.
- [ ] Start/stop/reload through existing runtime synchronization. Clean up partial
  starts and refresh process registration after replacement.
- [ ] Specify runtime stop, disable, logout, and archive/delete separately, including
  which credentials survive. Do not assume every provider has the same semantics.
- [ ] Keep unrelated connectors running when one account, listener, or backend fails.

### C. Connect messages, People and routing

Follow the [canonical message contract](../services/channels.md#message-structs)
and [message lifecycle responsibilities](../services/message-lifecycle.md#terms-and-module-responsibilities).

- [ ] Normalize native message/author/room/thread IDs and conversation facts at the
  adapter boundary. Carry the trusted connector in `Incoming.routing_context`.
- [ ] Preserve the minimal evidence needed for identity and history when sanitizing
  media. Removing raw secrets must not remove room, sender, or timestamp facts.
- [ ] Resolve People through the existing Engine/People path; names are display
  evidence, and profile lookup failure must not invent or elevate identity.
- [ ] Define authority through [IdentityScope](../../lib/zaq/channels/identity_scope.ex).
  Share a Person across connectors only when native identity authority or supported
  matching evidence justifies it. Preserve independent `PersonChannel` links.
- [ ] Let Engine select agent/workflow and history policy. Transport normalization
  must not hardcode an agent, grant permissions, or choose Direct/Shared strategy.
- [ ] Separate capture from response admission: an unmentioned room message may be
  stored without requesting a reply. Explicit None must prevent agent execution.
- [ ] Exercise self messages, imported history, ordinary queued messages, retries
  and duplicates. Do not use message age as a substitute for history classification.

### D. Complete delivery, replies, reactions and media

Use the [outbound flow](../services/channels.md#outbound-flow),
[formatting contract](../services/channels.md#outbound-message-formatting-channels-concern),
and [communication media contract](../services/channels.md#communication-media-attachments).

- [ ] Route replies, edits, typing, reactions, profile lookup, DM creation and media
  fetch through the selected connector's credentials and opaque adapter options.
- [ ] Render supported formatting for the provider and preserve Unicode. Keep
  provider formatting out of Agent prompts and canonical history.
- [ ] Map native reply/thread identity through the shared contract. Missing or
  inaccessible originals must not trigger guessed cross-connector lookup.
- [ ] Normalize reactions through adapter/shared event contracts, including
  multi-codepoint emoji and skin tones; retain exact message/connector targeting.
- [ ] Persist bounded media descriptors and provenance; materialize bytes lazily
  through authorized handles. Do not persist raw protocol payloads or reusable secrets.
- [ ] Verify history access separately from attachment provenance. Current canonical
  media authorization follows transcript access; unscoped handles retain their
  author check. See [materialization](../services/materialization.md#communication-media).
- [ ] Distinguish successful transport delivery from history association. Retrying
  association must not resend the external message.

### E. Expose the completed flow in BO

Follow [BO component guidance](../bo-components.md) and reuse configuration,
pairing, status and lifecycle components where their contracts fit.

- [ ] Expose supported fields and capabilities, account identity and actionable errors.
- [ ] Show both persisted configuration state and actual ingress readiness.
- [ ] Make destructive lifecycle consequences clear before confirmation.
- [ ] Ensure status polling and actions target the selected configuration.
- [ ] Keep credentials, raw session state and private diagnostics out of UI payloads,
  logs and persisted workflow events.

## 4. Reusable acceptance checklist

Copy this section into the feature issue. Mark each item pass, fail, blocked, or
not applicable with a reason; unchecked items are not acceptance evidence.
Record the application/adapter revisions, environment, connector aliases, observed
result and test/evidence reference. Use two connectors, two people and a group
where supported. Keep secrets and live QR/session material out of evidence.

### Configuration and recovery

- [ ] **Create:** authenticate → inspect detected account → confirm/save → one
  configuration exists → ingress becomes ready → a real round trip succeeds.
- [ ] **Expiring authentication:** let an individual QR/challenge expire; its
  replacement appears automatically and succeeds within the overall session window.
  An expired overall session requires a clear retry.
- [ ] **Cancel/retry:** cancel provisional onboarding without saving or leaking a
  runtime; retry failures and repeated confirmation without duplicate accounts.
- [ ] **Multiple configurations:** create A and B; each retains its own identity,
  settings, credentials, status and delivery route.
- [ ] **Agent assigned:** select an agent and send an eligible message; that agent
  replies through the receiving connector.
- [ ] **Agent None:** select explicit None and send the same message; no agent
  execution or automated answer occurs, with capture following the agreed policy.
- [ ] **Test send:** send to a known destination and verify sender account, recipient,
  formatted content and useful failure feedback for an invalid destination.
- [ ] **Restart:** stop and start the server; enabled saved connectors recover
  according to their session contract and exchange messages. Disabled/archived
  connectors stay stopped.
- [ ] **Disable/enable:** verify cancellation and confirmation, expected logout or
  session retention, and reconnection/relinking of the same saved configuration.
- [ ] **Isolation:** disable, restart or break A while B continues receiving/sending.
- [ ] **Settings edits:** explicit choices survive save/reload; listener-affecting
  changes restart the right runtime, while handler-only changes refresh appropriately.
- [ ] **Authorization:** an unauthorized operator, stale binding or wrong connector
  cannot inspect pairing secrets, mutate credentials or control another account.
- [ ] **Webhook verification, when supported:** valid deliveries and verification
  challenges work; invalid authentication and mismatched/disabled connectors are
  rejected without history capture or agent execution.

### Messages and People

- [ ] **Formatting:** receive representative text and send an answer containing
  supported Markdown, links, line breaks and Unicode; provider output is readable.
- [ ] **Person discovery:** first contact creates/resolves a Person with available
  name and phone/email; absent profile fields do not prevent valid discovery.
- [ ] **Multiple channel cards:** the same native identity on the same authority
  contacting A and B produces one Person with two connector cards.
- [ ] **Identity separation:** different native users with the same display name,
  or unrelated server authorities, are not merged by name alone.
- [ ] **Enrichment:** later profile data fills missing information without erasing
  explicit user edits; conflicting established identities fail safely.
- [ ] **Mention targeting:** mentioning account A does not count as mentioning B.
  Verify DMs, unmentioned rooms and configured room reply policies independently.
- [ ] **Replay/self/history:** retries do not duplicate canonical history; self
  messages and historical imports do not start unintended agent turns.

### History, replies, reactions and media

- [ ] **Direct:** send a DM and inspect channel history; evidenced one-to-one
  communication uses Direct strategy and the correct participant/configuration.
- [ ] **Shared:** send a group message and inspect history; supported room evidence
  produces Shared strategy. Verify recipient-addressed strategy separately if supported.
- [ ] **Passive capture:** send an unmentioned group message; history captures it
  under the supported policy without an agent reply.
- [ ] **Replies:** reply to a captured message, then to a reply. Verify the adapter's
  documented thread grouping and authorized original context, including after restart.
- [ ] **Missing/foreign originals:** deleted, unknown, inaccessible, other-room and
  other-connector reply targets do not leak content or use inline quotes as trusted history.
- [ ] **Reactions:** add/remove supported reactions, including skin tones; history
  or rating behavior applies to the correct message and connector.
- [ ] **Image without mention:** capture its descriptor in the transcript without
  starting an answer; later authorized history can materialize the attachment.
- [ ] **Image follow-up:** ask about the image later as its uploader and as another
  authorized participant; also check denied/revoked access and document the outcomes.
- [ ] **Image with mention:** mention the receiving account with an image; the
  assigned agent can use authorized media and reply.
- [ ] **Media failure:** unavailable/oversized media, disabled source connectors
  and invalid handles fail clearly without fetching through another account.
- [ ] **Delivery failure:** transport failure does not appear as confirmed delivery;
  successful sends followed by history failure recover without duplicate sends.

### WhatsApp-specific examples

Keep these as provider expectations, not universal requirements:

- Wait through multiple QR refreshes, then scan the current QR within the session
  window. Test against the adapter's actual QR and session lifetimes; host code
  must not invent those timers.
- Confirmation shows the detected phone and profile name; a missing name can fall
  back to the phone. Account confirmation requires an available phone.
- Runtime shutdown preserves pairing credentials. BO disable performs logout;
  enabling may require relinking. Durable pairing survives a server restart, while
  volatile message sessions may need re-establishment.
- Current WhatsApp reply identity uses the immediate replied-to message, not a
  single root shared by an entire reply chain.
- Verify image follow-ups for the uploader and other authorized participants.
  Current canonical media contracts use authorized transcript access; investigate
  any discrepancy and record limitations of the tested build.

## 5. Review and release evidence

Choose tests by boundary under the [testing handbook](../testing-approach.md):

| Test surface | Evidence to provide |
| --- | --- |
| Adapter contract | Native normalization, formatting, capability fallbacks, malformed input and protocol lifecycle. |
| Shared bridge contract | Another provider can use the new capability; unsupported adapters retain their behavior. |
| Runtime integration | Pair/save/start/send, replacement and stale events, restart, partial failure, and two-connector isolation. |
| Engine/People integration | Routing/None, identity authority, canonical capture, authorized history/media and delivery confirmation. |
| Property tests | Relevant invariants across settings, IDs, Unicode, malformed envelopes and permission defaults. |
| BO and approved E2E | Completed user journeys, failure presentation and account selection; real-provider checks cover behavior fixtures cannot prove. |

Existing test examples:

- [Shared adapter contracts](../../test/zaq/channels/jido_chat_bridge/shared_adapter_contract_test.exs)
- [Lifecycle and storage contracts](../../test/zaq/channels/linked_device/runtime_contracts_test.exs)
- [Person discovery and identity](../../test/zaq/people/whatsapp_profile_test.exs)
- [Sanitized media history](../../test/zaq/channels/sanitized_media_history_integration_test.exs)
- [Authorized reply history](../../test/zaq/engine/whatsapp_thread_history_test.exs)

Before requesting review:

- [ ] Recheck every new provider conditional in generic modules; justify it at the
  owning boundary or move the behavior into the adapter/shared contract.
- [ ] Remove abandoned paths and duplicate persistence/lifecycle implementations.
  Verify existing consumers when extending shared contracts.
- [ ] Include operation reuse evidence, capability limitations, rollout/rollback
  prerequisites and precise validation results in the PR.
- [ ] Follow the [validation lifecycle](../WORKFLOW_AGENT.md#phase-4--validate)
  and [coverage/final gate](../WORKFLOW_AGENT.md#phase-6--coverage-and-merge).
  Follow the separate approval rules for
  [existing test behavior](../testing-approach.md#existing-test-behavior-approval-gate)
  and [feature E2E](../testing-approach.md#feature-e2e-approval-gate).
- [ ] Update the owning service documentation and link any unsupported/deferred
  capability to its issue. Report mocked, automated and live-provider evidence
  accurately; passing one category does not establish the others.
