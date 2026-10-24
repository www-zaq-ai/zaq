# Channels Service

## Overview

For a new provider, follow the
[communication channel integration guide](../guides/communication-channel-integration.md)
for implementation sequencing, ownership checks and acceptance scenarios.

### Linked-device integration

Interactive authentication uses the optional `Jido.Chat.Adapter.authenticate/4`
contract through `CommunicationBridge` and `JidoChatBridge`. The confidential
`:pair_linked_device` Action revalidates the current super-admin on every command.
Adapters without this capability retain their existing configuration path.
The adapter owns provisional connections, challenges, expiry and cancellation;
Channels owns delegation and runtime activation. Private authentication and storage
requests use the trusted sink and never enter public message ingress.

After shared enable synchronization succeeds, BO opens the saved connection UI
only when the selected connector's capability snapshot declares
`connection_ui_on_enable: true` and authorized native authentication is available.
`JidoChatBridge` projects this capability for `:linked_device` ingress with native
adapter authentication. Native authentication alone does not select this UI;
provider names do not determine the post-enable presentation.

While that saved-profile connection is pending, the popup offers **Cancel
connection**. Cancellation reuses the shared disable flow, including adapter
cleanup before teardown, and closes the popup only after the profile is disabled.
Cleanup failure keeps the popup available for retry. Once connected, **Close**
only dismisses the popup. A cancellation already sent still disables if pairing
finishes before it is handled. New unsaved profiles retain provisional-session
cancellation.

New connector onboarding uses the same capability transport with `scope: :provider`,
without selecting a saved connector. `authentication_flow: :linked_device` selects
the existing provisional pairing UI after a current super-admin check; `:default`
preserves the standard form and OAuth flow. JidoChatBridge declares linked-device
authentication only for linked-device ingress with native adapter authentication.

Engine's trusted `:confirm_linked_device` Action persists a normalized account and
encoded credentials atomically, with attempt-scoped idempotence. Activation follows
persistence; a startup failure leaves a saved connector with runtime pending.
See [credential documents](engine.md#connector-credential-documents) for persistence
and authorization, and [shared extension contracts](#shared-adapter-extension-contracts)
for the adapter boundary. Provider-specific onboarding, transport settings and
recovery remain adapter-owned.

For normalization, identity resolution and confirmed delivery call chains across
roles, see the [message lifecycle sequences](message-lifecycle.md).

The Channels service provides transport and runtime infrastructure for communication adapters.

- **Data Sources** (ingestion channels in routes/API) ingest external documents (Google Drive, SharePoint, etc.).
- **Retrieval channels** receive user messages and deliver ZAQ responses (Mattermost, Slack, Teams, Email, Telegram, Discord).
- **Outbound HTTP** receives untrusted `http_request` events, asks Engine to prepare policy and credentials, then performs stateless DNS validation and transport execution.

Channel delivery uses canonical message payload structs (`Incoming` / `Outgoing`) defined in `lib/zaq/engine/messages/`; adapter-specific envelopes stay at the transport boundary. Cross-node routing follows the [Event/dispatch contract](../architecture.md#noderouter--critical). Existing `Zaq.Channels.Events` domain builders encapsulate specific request contracts, but are not a blanket requirement to replace direct Event construction.

`Zaq.People.IdentityResolver` checks that an ingress connector ID references a
retrieval configuration for the message provider (including IMAP-to-email),
then resolves authors and visible recipients through the shared People discovery
operation. Trusted private-channel readiness uses `resolve_channel_sender/1` and
the same connector validation, profile enrichment and discovery without fabricating
a message. Conversation binding/restoration belong to Conversations behind the
closed Engine boundary; Channels retains only transport correlation and projection.
`PersonIdentity` owns the native key `(platform, authority, identifier)`;
`PersonChannel` retains connector-specific routing and preferences. Channels'
`IdentityScope` defines authority: platform-global native IDs and normalized email
use their platform authority; server-scoped IDs use the canonical server
endpoint (including deployment path). Providers without attested tenant scope remain
connector-local. Bots on the same authority therefore reuse one Person without
requiring profile email. Normalized profile email can also join established People
across authorities. A caller-supplied `phone` remains identity evidence and
conflicting native/email/phone owners fail atomically. A phone returned by an
adapter's optional profile lookup is passed to People as `phone` and participates
in the same matching and conflict checks. A matching phone can link a new native
identity to an existing Person; contradictory established owners still fail
atomically. The phone can also fill a missing Person phone and populate a new
PersonChannel phone.
At the adapter boundary, `JidoChatBridge` omits unknown (`nil`) fields from typed
`Jido.Chat.UserInfo` profiles so a partial lookup does not erase message-provided
attributes. Explicit non-nil values and the existing map-profile mapping remain
unchanged; People does not filter empty profile fields during merging.
Unsupported or failed profile lookup leaves incoming identity resolution intact.
Incomplete profiles can receive later enrichment; explicit name and phone edits
remain authoritative. Editing a
connector endpoint cannot reinterpret a previously bound native identity.
Every PersonChannel requires a connector and native identity binding. The
connector-scope and native-identity migrations backfill legacy links from their sole matching
retrieval connector, counting disabled connectors as origins, then enforce
non-null scope and connector-specific uniqueness. Missing/ambiguous origins,
conflicting owners and changed established identity authorities abort migration;
operators must resolve those records before retrying. Ingress requires explicit
connector scope and never repairs or binds legacy rows at runtime.
Legacy email links retain their IMAP origin; where no inbox exists, the sole SMTP
connector is the sending-only origin. Profile-only emails are backfilled to the
default sender. New profile emails use that same default at creation; explicit
inbox origins are retained. Sending-only links never become incoming routing targets.
Engine's `ChannelConfig.resolve_person_channel_connector/2` resolves new links
from platform and optional origin using configuration-owned defaults; it does not
require a configured/running bridge. People owns transactional profile, identity
and channel persistence. Bridges do not select defaults for Person link creation.
Platform mapping reuses `Bridge.provider_to_bridge_key/1`.
`Bridge.incoming_routing/1` delegates incoming eligibility and topic IDs to the
communication connector. EmailBridge derives IMAP topics from existing mailbox
selection helpers and excludes sending-only connectors from incoming routing.
Module selection reuses
`Bridge.bridge_for/2` and never guesses a bridge. Actual sending uses each bridge's
existing `send_reply/2`; there is no separate notification preflight. Resolved sending
coordinates remain inside Channels; outgoing origin scope and application logs
are not rewritten. See [Notifications](notifications.md) for the consumer contract.
`CommunicationBridge.route_incoming_message/4` stamps the connector ID from
its configured bridge options and discards any ID supplied only in incoming
metadata. A caller bypassing that Channels ingress path still must not be
treated as a trusted provider event. `IncomingMessageRouter` discards valid
prefilled channel Person claims in both the request and actor and uses only
connector-scoped author resolution; invalid/conflicting claims fail validation.
BO web chat retains its internally trusted session-derived Person. This policy
trusts internal event callers; it does not authenticate an arbitrary caller at
`NodeRouter` or attest the event's stated provider/connector.

The provider's existing `Bridge.to_internal/2` path supplies typed
`routing_context.conversation_type` facts (`:one_to_one`, `:room`, or
`:recipient_addressed`), never a history strategy or title policy.
Jido Chat also checks its normalized room metadata against the adapter's
original event kind, configured provider, and room. `ChannelMeta.is_dm` defaults
to false, and some adapters default an absent kind to `:channel` or `:dm`;
neither default authorizes shared or direct history. The currently verified
kind matrix is Mattermost D/O/P (DM/public/private room), Telegram explicit
private/group/supergroup/channel, and Discord guild messages plus threads with
an explicit guild and parent. Discord Direct requires matching independently
fetched channel metadata with channel type 1; message `type` and absent guild
fields are not evidence. Unknown kinds, Mattermost group DM, Discord DM
without independent room evidence, and missing Discord thread parents remain
unknown. Slack and Teams have no configured adapter in `config/config.exs`.
Adapters that sanitize media must retain the transport facts required by their
provider's `IncomingNormalization.normalize/3` implementation. The shared bridge
has no fallback for missing raw evidence. These are trusted internal adapter
outputs, not authentication of arbitrary external messages.
This is only transport context, not authentication of arbitrary external
envelopes, a grant, passive capture, or a resolved Person. Engine resolves the
actor after routing; strategy consumers must use authorized transcript reads.
Unaddressed messages are delivered through `:receive_incoming_message`; Engine
decides capture without agent admission or a reply. Mattermost D/O/P, explicit Telegram kinds, and evidenced Discord guild
rooms/threads are bounded supported capture paths; unsupported or unknown kinds
do not become inferred Direct or Shared history. Only a complete Mattermost
room-member pagination result can drive a Shared provider-grant refresh; private
rooms still require the bot's own provider access. Other provider membership
refresh capabilities remain unsupported rather than inferred from a message.

Trusted Mattermost/Telegram ingress additionally normalizes `sender_membership`
only when the raw provider sender matches the adapter author in a verified room.
Sanitized media must preserve the sender evidence needed for the same author
consistency check without exposing private media fields.
After scoped Person resolution and canonical capture, Engine may bootstrap that
sender's provider grant once on the parent resource. This is message-local
presence, not a complete snapshot: replay or later posts cannot override removal
evidence, and re-entry requires a provider refresh or ordered membership event.
The grant uses the existing provider source so reconciliation/removal can revoke
it independently of manual access. Denied presence does not erase factual capture.
Engine retains snapshot scope: complete-room evidence fences absent senders,
whereas a targeted refresh/removal fences only its subjects. Unrelated first
contacts remain eligible for bootstrap. Legacy unversioned states whose scope
was not retained keep their conservative authority until verified reconciliation.

The unconsumed provider-multiplicity migration permits more than one connector
with the same provider. `ChannelConfig.resolve_by_provider/2` accepts an explicit
configuration ID and checks its provider and enabled status; provider-only
resolution fails on multiple enabled matches. Legacy provider-only upsert fails
on multiple stored matches instead of overwriting an arbitrary connector. The
remaining provider-only BO/runtime call sites are being audited under
`zaq-emb.21`; do not treat a provider string as a connector identity.
The BO retrieval-channel picker requires a connector selection when several
configs share a provider; routing changes and team browsing operate on that
chosen connector rather than the first configured row.
Conversation webhook subscriptions now target a URL ending in their numeric
connector ID. The Channels controller takes that ID from the URL rather than
the request body, then the bridge checks enabled provider/config consistency
before invoking the adapter's webhook validation. Old provider-only callback
URLs remain usable only for an unambiguous live provider; multiple configs
fail closed instead of selecting an arbitrary connector.
Person identity enrichment and DM backfill pass the ingress-stamped connector
ID to Channels; profile and DM calls use that connector's credentials and bot
identity, never a different live account of the same provider.
Provider-list ingress indicators query each enabled connector explicitly and
aggregate those results; details retain individual connector health. SMTP and IMAP
settings expose an explicit named Add Config flow, insert a distinct connector,
and select it after saving. Existing SMTP defaults and IMAP reply bindings remain
account-specific. BO reads and writes use the confidential
`:email_connector_settings` Engine event. Engine `EmailConnectorSettings` reloads an
exact connector ID and validates provider, kind, and archive state before saving;
form validation uses the cached snapshot. `SaveEmailConnector` accepts only form
fields and trusted execution actor context. A successful database write followed
by runtime failure is returned as saved with a pending runtime warning.
Engine sends the exact saved connector's bounded, resolved runtime configuration
through confidential `:sync_provider_runtime` with `%{config: runtime_config}`.
Channels uses the supplied map and existing provider runtime callback, without
connector reload or database-backed BO actor authorization. Enabled IMAP edits
restart that connector's listener; disabling stops it idempotently. The legacy
provider-only runtime-sync path still reads configuration and is outside this
incremental migration. Bootstrap and email delivery/attachment lookups have not
yet been made Repo-free. Connector archive persistence now belongs to Engine.

Canonical Incoming construction normalizes numeric room/thread identifiers using
the transport-neutral ConversationIdentity helper. External numeric IDs may be
negative (for example group chats); internal connector/Person IDs remain positive.
Channels stamps `routing_context.source_scope` for chat-local message identifiers
(Telegram uses its chat ID; IMAP uses its exact mailbox). Engine capture, admission,
locking and replay share `SourceIdentity.account_key/3`. Scope strings are opaque:
trimming can merge distinct mailbox identities, and malformed scopes never become
the connector-global `nil` namespace. Channels also stamps `identity_platform`,
message-local `Audience`, factual `conversation_type` and UTC `provider_sent_at`.
The conversation identity stamp carries
its explicit `scoped` policy; Engine never infers it from a provider name.
Chat providers produce those fields through provider-local normalization integrations
selected by existing provider registration, without history-specific configuration.
Mattermost, Telegram, and Discord validate provider-native room and
type evidence locally; `JidoChatBridge` consumes only the normalized result and
never interprets raw provider payloads as authorization. Administrative membership
and message lookup use consumer-neutral `room_capabilities/3`, `room_members/3`,
and `fetch_room_message/4` bridge operations. Their Channels events are
`:channel_room_capabilities`, `:channel_room_members`, and `:channel_room_message`.
Member snapshots distinguish complete room membership from message-local recipients;
Engine owns grant interpretation and detail-only root fallback.

Email normalization additionally supplies a `conversation_id` from the root RFC
References / In-Reply-To / Message-ID chain, separately from the sender-address
delivery route. Missing identifiers produce a distinct unthreaded conversation;
subjects never group inbound mail. Message-local audience evidence retains visible
sender/To/CC names and roles. Recipient discovery matches canonical People even when
they have no link to this inbox; inactive People remain inactive. Discovery alone
does not grant previous history. `ReplyTargets` carries explicit To/CC destinations
through Incoming and Outgoing. Reply-all uses Reply-To (or From) plus visible To/CC,
deduplicates addresses, and excludes configured inbox/sending addresses plus the
message-local receiving alias from the first `Delivered-To` header. The same
Channels-owned `SelfAddresses` filter removes self-addresses from normalized
discovery recipients and participants before People resolution or history capture.
The parser applies inbox/alias exclusions; the bridge adds only the selected SMTP
sender. Sender and reply-From metadata remain available as transport provenance.
Later delivery
hops do not establish additional self-addresses. For inbound replies, that receiving
alias is also the default From address, ahead of the configured inbox address and
SMTP sender fallback. SMTP authentication and connector selection remain independent
of the message's From address. Recipient exclusion always retains the configured
inbox address as well as the receiving alias and effective/configured SMTP senders.
Bcc and Delivered-To never infer hidden access or visible reply-all targets. The selected
SMTP connector remains authoritative; confirmed receipts enumerate the envelope
actually submitted successfully, feeding the existing history-association owner.

Inbound email replies carry `Auto-Submitted: auto-replied`; received automatic
replies use history-only capture and cannot trigger another agent turn. Exact
confirmed own-message echoes are acknowledged without capture or generation,
including when the automatic-reply header is absent. Channels supplies normalized
Message-ID/provider/connector/source coordinates to Engine's
`:confirmed_history_delivery` lookup against existing `HistoryIngress` confirmation
records. A sender address or Message-ID prefix alone never establishes an own echo.

Confirmed send/edit receipts retain `confirmation: :confirmed` and the provider
message ID normalized to the same nonempty string contract used by incoming events;
provider-native numeric IDs never cross into Engine confirmation. `DeliveryConfirmation`
forwards the receipt and bounded outgoing context through Engine's neutral
`:record_delivery_confirmation` event. Engine `History.Delivery` alone interprets
that evidence for canonical association. History failures retain a bounded
error category and `history_capture: :unavailable` without changing send success.
If the Engine event itself cannot be processed, Channels preserves the confirmed
receipt with neutral `confirmation_recording: :unavailable` instead of inventing
a history result. Receipt facts use `audience`, `conversation_id`, and `source_scope`;
visible header recipients and the successfully submitted envelope remain distinct.
The Engine records canonical message and target references atomically with ID-only
association jobs; `HistoryIngress` owns immediate processing and recovery. This path
never resends and is shared with PR B's delivery lifecycle.
Pending receipts, failed sends and persisted generation alone are not confirmations.
Delayed terminal delivery keeps those boundaries separate: ordered intermediary
upserts complete before terminal delivery, but even a completed canonical answer
is not associated with the channel until the real send/edit receipt is confirmed.
A gateway or client receive timeout leaves generation intact without claiming
delivery; a late server response after the sender exits cannot confirm it.
Association recovery uses `HistoryDeliveryWorker` only after recorded confirmation
and never resends transport. The real Mattermost/Jido integration suite exercises
delayed success, gateway failure and the native HTTP receive deadline with a full
Arabic answer; synchronous status regressions cover blocked partial/final ordering.
Pipeline replies carry the incoming routing context separately from metadata;
delivery selects the matching connector credentials. A provider-only reply is
allowed only when the provider has one unambiguous active connector.
Intermediate status upserts use the same ingress routing context, rather than
metadata-claimed connector IDs, for edits to the provider message.
The dedicated SMTP and IMAP settings pages show connector bars; with multiple
accounts they require an explicit selection before editing. SMTP notification
delivery uses a sole enabled connector or an administrator-designated default
(`ChannelConfig.set_default_smtp_connector/1`); multiple live accounts with no
enabled default fail closed. Disabling or archiving the default does not silently
promote a different account. IMAP settings bind each inbox to an enabled SMTP
connector for replies. Legacy unbound inboxes can use a sole SMTP connector,
but multiple SMTP accounts require a binding even with a notification default.
Disabled or archived bindings fail closed rather than falling back.
Data-source watch registration and renewal use the selected connector ID in
their callback URLs. Engine keys watch rows by connector, provider, and external
watch ID; a legacy provider-only delivery with colliding watch IDs fails closed
rather than choosing the first account. Verified webhook jobs pass their
persisted connector ID through the Engine watch lookup, and scoped webhook
dispatch checks provider/config consistency before invoking an adapter.
Target-source watch lookups likewise reject matches across connectors; within
one connector they use the latest matching watch. An explicitly supplied but
malformed connector ID is rejected instead of becoming an unscoped lookup.
BO connector removal archives rather than deletes the config: it disables
runtime selection, retains historical lookup by ID and preserves the FK of
PersonChannel identities. Archived configs are excluded from ordinary BO
lists and provider-only upserts. Delete first tears down ingress, prepares adapter
disablement, stops the runtime, then persists the disabled state before
archiving. Preparation failures leave the configuration enabled; runtime stop
failures leave it disabled and unarchived so the BO can retry Delete.
For data-source connectors, archiving first unwatches each active/error watch;
successful stops are persisted and failed IDs remain retryable with the connector
still live. The post-archive reconciliation and late watch upserts schedule
durable cleanup on the existing renewal worker. Only this cleanup path may use
archived credentials to unwatch the exact matching connector; regular ingress
and watch creation remain unavailable after archive.
Engine `ConnectorLifecycle` owns archive descriptor/revision validation, watch ordering
and configuration persistence. BO Enable/Disable dispatches the existing Engine
`:connector_lifecycle` command; Engine uses the original `:sync_channel_runtime`
before/after configuration request. Channels checks the optional bridge
`before_disable/3` hook before running the existing runtime synchronization. Engine
performs this call before writing disabled, keeping credentials available during
logout. Save and enable continue to use the original runtime-sync contract.
BO selects confirmation from the exact connector capability snapshot's
`resolved.logout_on_disable` flag. Adapters without logout retain normal teardown.
JidoChatBridge loads the configured adapter, detects optional `logout/1`, enforces
super-admin permission and waits for logout before teardown. A failed logout prevents
teardown and disable persistence. Missing listeners use saved-binding cleanup;
local cleanup alone does not prove remote device unlinking.

Archive retains its existing watch and webhook teardown followed by confidential
`:connector_sync_runtime`. That existing runtime-stop handler uses the same optional
pre-disable hook before stopping the runtime. Engine persists disabled afterward
and refuses archival on runtime failure. Already-disabled archive retries skip
logout and retry runtime shutdown. Archived rows reconcile runtime and watch cleanup.
These Channels events perform no configuration persistence. The shared Engine
command owns enable/disable persistence; Channels does not perform an Engine
prepare/persist callback sequence. There is no controller,
stopping state or router coordination.
The public result contains IDs and bounded outcomes, never credentials.

### Replicated email history contract (#768)

Associate each email message with its sender's history and with the histories
of addresses in that message's visible To and Cc headers. Product policy treats
those headers as authorized recipients, not as verified SMTP-delivery evidence.
Include a hidden Bcc address only when the receiving account is independently
identified by its connector or a successful outbound delivery records that
address in its SMTP envelope. An IMAP folder name such as `INBOX`, or a
`Delivered-To` header alone, does not establish the account's email identity.
If that evidence is unavailable, do not invent a Bcc recipient.

Associations are **per message**: adding an address to To/Cc on a later reply
does not expose any earlier messages. Apply the same rule to bot replies, using
the actual sender and that reply's own recipient evidence. The IMAP parser
records the sender and all visible To/Cc addresses in the typed incoming
routing context. When RFC headers are available, it does not substitute an
envelope recipient for a missing To/Cc header; `Delivered-To` remains only a
reply-routing hint. It never infers hidden Bcc from the selected mailbox.
SMTP delivery's receipt-bearing variant returns the actual Swoosh sender and
envelope recipients only after `Mailer.deliver/2` succeeds. Legacy notification
callers still receive `:ok` or an error. EmailBridge includes that evidence in
the outbound reply receipt when available; a legacy sender stub's `:ok` alone
does not provide evidence. This is transport evidence, **not** Person identity,
an access grant, or proof of mailbox arrival. The read-only People identity
resolver consumes the normalized `Audience` namespace and identifiers only on the
enabled, matching connector; it never creates recipient People or falls back to
an unscoped/other connector identity. Engine does not parse email headers or
reconstruct mailboxes from metadata. The caller must still attest adapter
provenance before using those matches for capture.

### People authentication rate ownership (V1)

`Zaq.Channels.PeopleAuthRateLimiter` is the first child of the static
`Zaq.Channels.Supervisor`, before `Zaq.Channels.BridgeSupervisor`. It owns only unsuccessful-identification IP
protection via `check_identification/1` (non-consuming) and
`record_failed_identification/1`. Both use local counters and a background-refreshed
typed config snapshot; neither queries Repo nor dispatches to Engine. Missing,
expired or failed config denies locally. Engine retains OTP Person/IP issuance
budgets and persisted verification attempts. Shared Hammer mechanics use separate
role tables/listeners/topics, including on combined-role nodes.

Public authentication orchestration remains PR4: precheck before one Engine
resolve/eligible/issue request, then record only its unknown/ineligible response.
There is no broad ingress ceiling or separate eligibility lookup call. See
[rate topology and retry behavior](people-access.md#rate-topology-and-retry-behavior)
for cache refresh/expiry and eventual-consistency limitations.

### People authentication rate ownership (V1)

`Zaq.Channels.PeopleAuthRateLimiter` is the first child of the static
`Zaq.Channels.Supervisor`, before `Zaq.Channels.BridgeSupervisor`. It owns only unsuccessful-identification IP
protection via `check_identification/1` (non-consuming) and
`record_failed_identification/1`. Both use local counters and a background-refreshed
typed config snapshot; neither queries Repo nor dispatches to Engine. Missing,
expired or failed config denies locally. Engine retains OTP Person/IP issuance
budgets and persisted verification attempts. Shared Hammer mechanics use separate
role tables/listeners/topics, including on combined-role nodes.

Public authentication uses `Zaq.Channels.PeopleAuth`: precheck before one confidential
Engine resolve/eligible/issue/notify request, then record only its unknown/ineligible response.
People HTTP forms use only the direct peer `conn.remote_ip`, ignoring forwarded
client-IP headers. Public routes and their independent session contract are in
[People authentication](people-access.md#public-people-authentication-pr4).
There is no broad ingress ceiling or separate eligibility lookup call. See
[rate topology and retry behavior](people-access.md#rate-topology-and-retry-behavior)
for cache refresh/expiry and eventual-consistency limitations.

### People authentication rate ownership (V1)

`Zaq.Channels.PeopleAuthRateLimiter` is the first child of the static
`Zaq.Channels.Supervisor`, before `Zaq.Channels.BridgeSupervisor`. It owns only unsuccessful-identification IP
protection via `check_identification/1` (non-consuming) and
`record_failed_identification/1`. Both use local counters and a background-refreshed
typed config snapshot; neither queries Repo nor dispatches to Engine. Missing,
expired or failed config denies locally. Engine retains OTP Person/IP issuance
budgets and persisted verification attempts. Shared Hammer mechanics use separate
role tables/listeners/topics, including on combined-role nodes.

Public authentication uses `Zaq.Channels.PeopleAuth`: precheck before one confidential
Engine resolve/eligible/issue/notify request, then record only its unknown/ineligible response.
People HTTP forms use only the direct peer `conn.remote_ip`, ignoring forwarded
client-IP headers. Public routes and their independent session contract are in
[People authentication](people-access.md#public-people-authentication-pr4).
There is no broad ingress ceiling or separate eligibility lookup call. See
[rate topology and retry behavior](people-access.md#rate-topology-and-retry-behavior)
for cache refresh/expiry and eventual-consistency limitations.

---

## Module Map

| Module                              | File                                         | Role                                            |
| ----------------------------------- | -------------------------------------------- | ----------------------------------------------- |
| `Zaq.Channels.Api`                  | `lib/zaq/channels/api.ex`                    | Channels role boundary for `NodeRouter` events  |
| `Zaq.Channels.CommunicationBridge`  | `lib/zaq/channels/communication_bridge.ex`   | Communication-domain routing/delegation helpers |
| `Zaq.Channels.DataSourceBridge`     | `lib/zaq/channels/data_source_bridge.ex`     | DataSource-domain routing/delegation helpers    |
| `Zaq.Channels.Materializers.DataSourceDocument` | `lib/zaq/channels/materializers/data_source_document.ex` | Data-source record materialization handler |
| `Zaq.Channels.Materializers.CommunicationMedia` | `lib/zaq/channels/materializers/communication_media.ex` | Communication-media record materialization handler |
| `Zaq.Channels.Bridge`               | `lib/zaq/channels/bridge.ex`                 | Bridge behaviour + shared helpers               |
| `Zaq.Channels.JidoChatBridge`       | `lib/zaq/channels/jido_chat_bridge.ex`       | Provider bridge for jido_chat adapters          |
| `Zaq.Channels.JidoConnectBridge`    | `lib/zaq/channels/jido_connect_bridge.ex`    | Provider bridge for jido_connect data sources   |
| `Zaq.Channels.JidoChatBridge.State` | `lib/zaq/channels/jido_chat_bridge/state.ex` | Per-bridge GenServer state holder               |
| `Zaq.Channels.EmailBridge`          | `lib/zaq/channels/email_bridge.ex`           | Bridge for email IMAP ingress, SMTP delivery, and attachment materialization |
| `Zaq.Channels.WebBridge`            | `lib/zaq/channels/web_bridge.ex`             | Bridge for web/ChatLive sessions via PubSub     |
| `Zaq.Channels.Web.*`                | `lib/zaq/channels/web/`                      | Shared BO/widget transport contracts            |
| `Zaq.Channels.Supervisor`           | `lib/zaq/channels/supervisor.ex`             | Static role parent and public runtime facade    |
| `Zaq.Channels.BridgeSupervisor`     | `lib/zaq/channels/bridge_supervisor.ex`      | Dynamic bridge runtime lifecycle and bootstrap  |
| `Zaq.Channels.ConnectorRuntime`     | `lib/zaq/channels/connector_runtime.ex`      | Repo-free supplied-config archive runtime stages |
| `Zaq.Engine.Connect`                | `lib/zaq/engine/connect.ex`                  | Credential/grant lifecycle for Data Source auth |
| `Zaq.Channels.RetrievalChannel`     | `lib/zaq/channels/retrieval_channel.ex`      | Ecto schema — per-channel subscriptions         |
| `Zaq.Channels.MattermostAdmin`      | `lib/zaq/channels/mattermost_admin.ex`       | Admin helpers for Mattermost UI                 |
| `Zaq.ConnectorConfig.SmtpSettings`  | `lib/zaq/connector_config/smtp_settings.ex`  | Shared pure SMTP settings access                 |
| `Zaq.Engine.Messages.Incoming`      | `lib/zaq/engine/messages/incoming.ex`        | Canonical inbound message struct                |
| `Zaq.Engine.Messages.Outgoing`      | `lib/zaq/engine/messages/outgoing.ex`        | Canonical outbound message struct               |

---

## Web transport contracts

`Zaq.Channels.Web.Message` and `Zaq.Channels.Web.Command` are the shared adapter-facing
inputs for BO chat and web widget adapters. They are not replacements for Engine
`Incoming`/`Outgoing`: WebBridge owns the translation from a validated `Message` into
canonical `Incoming`, while commands represent non-message operations such as conversation
initialization and history retrieval.

Trusted values remain separate from adapter-decoded payloads:

- `Zaq.Channels.Web.Context` carries trusted identity/configuration and BO's explicit
  capabilities/routing inputs. Nil actor never grants a BO capability; widget Context
  instead requires the adapter-verified sender and scoped connector identity.
- `Zaq.Channels.Web.Delivery` carries a server-resolved PubSub topic and a closed semantic
  event mapping. Browser payloads must not construct or override it.
- `Zaq.Channels.Web.Response` is the versioned semantic result before adapter wire encoding;
  it rejects private execution and credential fields.

The detailed [WebBridge protocol](web-bridge.md) owns field/signature tables, message
translation, command results, trusted identity, response/event projection, ordering,
timeouts, restoration and version compatibility. Its
[runtime construction contract](web-bridge.md#widget-runtime-construction) describes
adapter-owned children and the fixed config-bound sink; the
[integration handoff](../guides/web-widget-integration.md) supplies installation examples
and external acceptance responsibilities.

Channels exposes the closed `:web_ingress` action through NodeRouter and preserves the
trusted serialized Delivery reference across Engine/Agent hops. BO remains on its
authenticated session policy; widget requests use connector-scoped People identity and
private Direct history. Only an actual widget question creates a chat. These are host-side
integration seams, not an installed widget endpoint or an endpoint-security guarantee.

---

## Materialization Handles

Channel materializers redeem signed handles through `Zaq.Materialization`. Runtime
materialization options are JSON-compatible maps with string keys only; caller-facing
tools may accept atom-keyed Elixir params, but must normalize them before calling
`Zaq.Materialization.materialize/4` or handler `materialize/3` functions.

---

## Data Source Credentials and Grants

Data Source provider configs in BO (`/bo/channels/ingestion/:provider`) can attach
reusable Connect credentials and claim context-bound grants.

At System Configuration level (`/bo/system-config?tab=credentials`), admins can list
all Connect credentials and open a grants modal per credential to review every
grant bound to that credential.

- Credential definitions are provider-scoped and reusable.
- Grants are bound to resource + owner context (for Data Sources, `resource_type: "data_source"`).
- Connect auth kinds currently supported in ZAQ are `oauth2`, `api_key`, and `jwt_bearer`.
- `jwt_bearer` stays provider-agnostic in ZAQ (`issuer`/`private_key`/`key_id` plus metadata profile), while connector-specific profile setup remains in `jido_connect` integrations.
- OAuth2 claims open in a popup and finalize through the channels node callback:
  - `GET /channels/oauth2/:provider/redirect`
  - callback page posts result to the opener and auto-closes.

The callback route remains minimal; claim context is carried in signed OAuth state.

---

## Message Structs

### `Zaq.Engine.Messages.Incoming`

Canonical struct for all inbound messages crossing the adapter boundary. Every adapter must map its transport-specific payload to this struct before passing a message to any ZAQ component.

When routed across nodes, this payload is carried in `%Zaq.Event.request`.

```elixir
@enforce_keys [:content, :channel_id, :provider]

defstruct [
  :content,       # String — message text
  :channel_id,    # String — platform channel ID
  :author_id,     # String | nil
  :author_name,   # String | nil
  :thread_id,     # String | nil
  :message_id,    # String | integer | nil
  :provider,      # atom | String — e.g. :mattermost, :web
  :person,        # %{id: integer, full_name: string | nil, team_ids: [integer]} | nil
  attachments: [],
  routing_context: %Zaq.Engine.Messages.Incoming.RoutingContext{},
  is_dm: false,
  metadata: %{},
  content_filter: []
]
```

Channel adapters populate transport identity fields such as `author_id` and
`author_name`. Engine resolves the canonical `Incoming.person` payload before applying
incoming-message routing policy. Agent and Engine boundaries promote that identity into
canonical `%Zaq.Event.actor` via `Zaq.Identity.ActorNormalizer`. The incoming payload is
intentionally minimal and JSON-safe because `%Incoming{}` may cross nodes.

Incoming routing facts belong to `Incoming.routing_context`, not ad-hoc metadata or
provider settings. Communication bridges may populate `channel_config_id`,
`retrieval_channel_id`, and provider-normalized `topic_id` values such as an IMAP
mailbox. They must not resolve the destination agent or workflow; final routing policy
is resolved by Engine through `Zaq.Engine.IncomingMessageRouter` and
`Zaq.Engine.IncomingMessageRoutingRule`.

`JidoChatBridge.to_internal/2` maps the adapter's `external_thread_id` to
`Incoming.thread_id`. The adapter owns the provider's thread-reference semantics.
Original content comes from Engine-authorized history; thread references do not
grant access or inject adapter quote text. Native outgoing quote options are
independent of history grouping.

BO routing writes for global defaults, provider defaults, retrieval-channel assignments,
and IMAP mailbox rules dispatch to Engine action `:upsert_incoming_message_routing_rules`.
The registered tool `message.upsert_incoming_routing_rules` uses the same Engine dispatch
path for agents and workflows. IMAP mailbox saves use the action's batch `rules` input.
The People BO page uses the same action for person-scoped global, provider,
retrieval-channel, and IMAP mailbox routing overrides; email person channels map to
the receiving `email:imap` config, not `email:smtp` delivery config.

### `Zaq.Engine.Messages.Outgoing`

Canonical struct for all outbound messages. Produced by `Zaq.Agent.Pipeline.run/2` and by the Notification center. Delivered through `Zaq.Channels.Events.build_and_dispatch_deliver_outgoing_event/2` to `Zaq.Channels.Api` (`:deliver_outgoing`).

When routed across nodes, this payload is typically returned in `%Zaq.Event.response`.

```elixir
@enforce_keys [:body, :channel_id, :provider]

defstruct [
  :body,          # String — response text
  :channel_id,    # String
  :thread_id,     # String | nil
  :author_id,     # String | nil
  :author_name,   # String | nil
  :provider,      # atom | String
  :in_reply_to,   # String | nil — message_id being replied to
  metadata: %{}
]
```

`Outgoing.from_pipeline_result/2` builds an `%Outgoing{}` from an `%Incoming{}` and a pipeline result map, copying routing fields and merging metadata.

Agent failure payloads use the canonical `Zaq.Agent.ErrorMessage` mapping. Their
metadata may include an allowlisted reason, recovery category and retryability flag,
but never credential/grant IDs or raw provider diagnostics. Channels format and
transport the canonical message; bridges must not reclassify failures or construct
provider-specific credential guidance.

For `:personal_credentials` recovery, `MessageFormatter` appends the fixed
`/people/credentials` destination built by `Zaq.Channels.PeoplePortalUrl` from Global
settings → global base URL. Channels obtains the persisted value through the existing
Engine `:system_config_get_global_base_url` action; only validation and fixed-path
composition remain local. Deployment path prefixes are preserved. Missing, unsafe,
malformed or unavailable Engine responses produce administrator guidance instead of a
broken link. The non-secret lookup uses a normal observable event. This formatting
contract does not own People authentication or post-login redirection.

### Communication media attachments

Communication bridges map inbound media to lazy `Zaq.Contracts.Record` values in
`Incoming.attachments`. `Record.attachment_metadata/1` persists bounded display
fields and `attributes["materialization_source"]`, a versioned Channels-owned
source payload. Its locator retains exact provider/config/reference and original
author/channel/message provenance, including IMAP coordinates where applicable.
Runtime handles, aliases, bytes, raw provider internals, credentials and events
are excluded. Engine treats the source payload as opaque JSON-safe metadata.

After successful canonical execution admission or history authorization, Engine
API dispatches confidential `:hydrate_attachments` batches to Channels, outside
database transactions. Each descriptor is wrapped with its message's canonical
transcript/message UUIDs, including the actual parent placement for thread context.
`CommunicationMedia.hydrate/2` reconstructs lazy Records and signs those UUIDs in
a versioned runtime claim alongside the unchanged stored provider source facts.
Hydration performs no provider I/O. Legacy, malformed or unauthorized attachments
retain display metadata with `materialization_status: "unavailable"`; transport
failures return `:attachment_hydration_unavailable`. No URL or connector is guessed.

Fetch-controlling fields are bound into a signed `materialization_handle` with
type `communication_media`. `Zaq.Materialization` verifies the handle before the
trusted materializer dispatches the existing `:materialize_record` Channels event.
Canonical handles inherit current transcript-read permissions: the materializer
reads the exact authorized canonical message through the existing Engine
`:conversation` event and matches its stored attachment source in Channels before
fetching. Source-author identity remains provenance, not an access restriction.
Unscoped handles retain their existing author check; canonical scope errors never
downgrade to it. See [communication materialization](materialization.md#communication-media)
for the authorization, revocation and deployment contracts.

The handle also carries signed source provenance such as `channel_config_id`,
`source_channel_id`, and `source_message_id` when the adapter provides them.
Bridges may use those signed fields for exact source routing. IMAP attachment
redemption requires the exact enabled `email:imap` `channel_config_id`, then
rechecks `UIDVALIDITY` before fetching the requested MIME section.

When an agent accesses a persisted attachment, `CommunicationBridge` uses the
verified request's provider and, when present, exact config id to route to the
correct bridge. Jido chat providers call their adapter's `fetch_media/2`; email
calls `EmailBridge.materialize_record/3`, which delegates to
`ImapAdapter.download_attachment/2`. The 100 MiB default byte limit is
configurable through `:message_trace_artifact_max_bytes`; declared sizes above
that limit are rejected before provider fetch and downloaded bytes are checked
again before returning content.

---

## Channels API and Communication Routing

`Zaq.Channels.Api` is the role boundary entrypoint for channel delivery/runtime events. Callers use `NodeRouter.dispatch/1` with `%Zaq.Event{}` and a supported domain action, preserving trusted actor and runtime opts. Inspect this API and any domain event builder for the request contract; do not use generic invocation as a fallback for a missing action.

`Zaq.Channels.CommunicationBridge` owns provider normalization, bridge resolution, and delivery/runtime delegation helpers.

`Zaq.Channels.DataSourceBridge` owns provider normalization, bridge resolution, and DataSource operation delegation (`auth_handshake`, `list_resources`, `download_resource`, `list_files`, file CRUD/search, listener setup/teardown, provider watch setup/teardown, and webhook normalization).

Source scopes separate selection identity (`scope_id`) from provider listing filters.
`JidoConnectBridge.list_source_scopes/2` keeps the config-backed scope identity and
supplies the provider root from `ProviderCatalog` (`root` for Google Drive, `/` for
SharePoint). Disk continues to expose one scope per volume. An explicit empty
filter map is valid and must not be replaced with a parent inferred from the scope
identity. BO browsers preserve these filters at the root and use canonical Record
IDs, not joined display paths, when entering folders. Child listings disable
shared-item inclusion; returning to the root restores the source filters.

Data-source file callbacks receive `%Zaq.Events.TrustedContext{}` separately from provider
parameters. `Zaq.Channels.Api` derives it only from the incoming event envelope; bridges must
never derive actors or `skip_permissions` from request parameters. New code puts permission
bypass in top-level runtime context or `event.opts[:skip_permissions]`, not in actor maps;
actor-carried bypass is a compatibility input only. Bridges that dispatch to another role,
such as `DiskBridge` dispatching to Storage, project the same trusted context through that
role's event helper.

`Zaq.Channels.DataSourceBridge` enforces Record permissions by default for file reads and
mutations. Bridges normalize provider principals into permission Records with canonical
`principal.channel`, `principal.identifier`, and `access_rights`; the global boundary matches
those grants against the trusted actor's People-directory identity. Signed-Record mutations
are authorized before the bridge callback runs, and callback params contain only provider
business fields such as `file_id`, `config_id`, metadata, and content. Provider-based updates
are available only to bridges that implement `owns_permission_checks?/0` and return `true`;
Disk does this because Storage owns source ACLs and checks them with current filesystem
context.

Disk filename searches honor the optional `path`: use a volume name, a canonical
`volume/folder` path, or a catalog folder id to search that subtree recursively.
An absent/empty path, `/`, or `.` searches all volumes of the selected disk
configuration. Explicit unresolved scopes fail rather than broadening the search;
volume-boundary traversal is rejected. Scoped results still undergo the same
Storage read-permission checks as unscoped searches.

Unmaterialized data-source file records carry a signed `materialization_handle` of type
`data_source_document`. The handle survives agent/tool JSON serialization and is redeemed
through `Zaq.Materialization`; the Channels materializer validates the locator and dispatches
the fixed `:data_source_download_document` action. The handle is a bearer capability disclosed
only on Records the caller was authorized to read, so redemption does not repeat the provider
permission check.

Unmaterialized communication-media records carry a signed `materialization_handle`
of type `communication_media`. The handle is redeemed through the same
`Zaq.Materialization` registry and dispatches the generic `:materialize_record`
Channels action after locator and actor validation.

### Data source required capabilities

`Zaq.Channels.DataSourceBridge.required_capabilities/0` defines the standardized capability contract ZAQ expects connectors to support:

- `list_items`
- `count_items`
- `list_principals`
- `count_principals`
- `get_item_metadata`
- `list_item_versions`
- `download_items`
- `create_item` — umbrella write support for empty files, content uploads, and folders
- `update_item`
- `delete_item`
- `manage_item_permissions`
- `search_items`
- `sheet_inspect`
- `sheet_get`
- `sheet_create`
- `sheet_add_tab`
- `sheet_update_values`
- `sheet_append_values`
- `sheet_clear_values`
- `sheet_delete_tab`
- `watch_changes_webhook`
- `receive_change_webhook`

`Zaq.Channels.ProviderCatalog` maps provider watch work to connector actions such as `collection.watch`, `collection.changes.list`, and `channel.stop` when the provider exposes them.

### Data source API actions

`Zaq.Channels.Api.handle_event/3` exposes the following data-source actions:

- `:data_source_auth_handshake`
- `:data_source_list_resources`
- `:data_source_download_resource`
- `:data_source_list_files`
- `:data_source_create_file`
- `:data_source_get_file`
- `:data_source_update_file` — accepts `%{record: %Zaq.Contracts.Record{}, params: map()}`; Channels verifies record provenance, derives provider/config/file identity from signed claims, and forwards only update fields to the provider bridge. The agent-facing `update_document` tool requires mutations under `changes` (`name`, `content`, `path`, `parent_id`, `mime_type`); `path` means destination parent path and must be omitted for content-only edits and renames.
- `:data_source_delete_file` — accepts `%{record: %Zaq.Contracts.Record{}}`; Channels translates the record to provider parameters at the data-source bridge boundary.
- `:data_source_search_files`
- `:data_source_list_permissions`
- `:data_source_replace_permissions` — provider/config-based full direct-ACL replacement used by the Ingestion UI; available only when the bridge owns source permission checks. After the bridge write, Channels dispatches the returned affected ids to Ingestion for projection refresh.
- `:data_source_update_permissions` — accepts a provenance-bearing file or folder Record plus incremental direct grants/revocations. Channels derives provider/config/file identity from signed provenance and delegates only to bridges implementing `update_permissions/3`; Disk delegates the source ACL write to Storage. Ingestion is notified only after the bridge succeeds.
- `:data_source_setup_listener`
- `:data_source_teardown_listener`
- `:data_source_channel_stats`
- `:data_source_watch_item`
- `:data_source_unwatch_item`
- `:data_source_oauth_authorize_url`
- `:data_source_oauth_exchange_code`
- `:data_source_oauth_refresh_token`
- `:data_source_oauth_default_scopes`

`Zaq.Channels.Bridge` provides shared bridge behaviour callbacks and runtime helper defaults.

Provider watch calls are provider-facing only. Durable watch-channel runtime state is stored by `Zaq.Engine.DataSources`; Channels passes provider responses to Engine through `NodeRouter.dispatch/1` and does not own checkpoint persistence.

### Webhook ingress

Webhook deliveries enter through:

- `POST /channels/webhook/:type/:provider`

Supported `:type` values:

- `conversation` — delegated to `Zaq.Channels.CommunicationBridge.handle_webhook/2`
- `data_source` — delegated to `Zaq.Channels.DataSourceBridge.handle_webhook/2`

The controller wraps each request into a normalized payload map before dispatch:

```elixir
%{
  "method" => conn.method,
  "path" => conn.request_path,
  "headers" => Map.new(conn.req_headers),
  "query" => conn.query_params,
  "payload" => body_payload,
  "raw" => conn.assigns[:raw_body]
}
```

Response behavior:

- Conversation providers can return `%{webhook_response: %{status, headers, body}}` to pass through transport-specific verification responses.
- Data source providers return accepted/rejected JSON envelopes from the channels controller.
- For `jido_connect` data-source webhooks, verification remains synchronous in `handle_webhook/2`, then post-verification processing runs asynchronously via `Zaq.Channels.JidoConnectBridge.WebhookWorker` on the `:channels` queue.
- Data-source collection webhooks are metadata-only. Channels normalizes the delivery, resolves the Engine watch channel, calls the provider's collection change listing action with the stored checkpoint, and dispatches the resulting signals to Engine.
- Changed collection metadata is converted to canonical Records in Channels. Both collection changes and successful file-watch metadata reads use `DataSourceBridge.seal_response/2`, including recursive permission sealing, before Engine handoff. Sparse tombstones and synthetic metadata-read fallbacks are not issued provenance. Watch notifications do not mint new materialization handles or grant permission bypass.
- Provider sync notifications, such as Google Drive `resource_state: "sync"`, are accepted but treated as no-ops.
- Public webhook URLs are built with `Zaq.Channels.WebhookUrl` from `system.global.base_url`. If the global base URL is unset, external provider watch setup is unavailable until configured.

Authentication and signature verification are provider-specific and handled inside bridge/verifier modules (for example jido_connect webhook verifiers and jido_chat adapter webhook handlers).

## Communication Bridge Helpers

`Zaq.Channels.CommunicationBridge` is the stateless helper boundary used by API/bridge flows for provider-targeted operations.

### Incoming person shape

When a bridge dispatches an incoming-routing event, Engine resolves the incoming message
`person` from the channel author before returning the executable Agent event:

```elixir
%{
  id: person_id,
  full_name: full_name,
  team_ids: team_ids
}
```

`author_id` and `author_name` remain provider identity fields on `%Incoming{}`.
`person.id` is the ZAQ Person ID and is present only when the channel author resolves
to a Person. Engine incoming routing promotes the normalized identity into
`%Zaq.Event.actor` before the event continues to Agent.

### Public API

| Function                     | Description                                                  |
| ---------------------------- | ------------------------------------------------------------ |
| `send_typing/2`              | Sends typing indicator through the provider bridge           |
| `add_reaction/4`             | Adds a reaction through the provider bridge                  |
| `remove_reaction/5`          | Removes a reaction through the provider bridge               |
| `subscribe_thread_reply/3`   | Subscribes to thread replies via provider bridge             |
| `unsubscribe_thread_reply/3` | Unsubscribes from thread replies via provider bridge         |
| `sync_config_runtime/2`      | Synchronizes runtime processes when a channel config changes |
| `test_connection/2`          | Runs bridge-specific connection test                         |
| `bridge_for/2`               | Returns the configured bridge module for a provider          |
| `route_incoming_message/4`   | Dispatches a canonical `%Incoming{}` to Engine routing       |
| `materialize_record/2`       | Routes a verified communication-media materialization request |

### Bridge resolution

Bridges are resolved from `Zaq.Config.get(:zaq, :channels, %{}, opts)` by provider atom key. Production uses the default `Zaq.Config` module, which delegates to `Application.get_env/3`; tests can pass `config: TestConfig` through opts or `%Zaq.Event.opts` for async-safe overrides.

```elixir
# Example config shape
config :zaq, :channels, %{
  mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: ..., ingress_mode: :websocket},
  email:      %{bridge: Zaq.Channels.EmailBridge},
  web:        %{bridge: Zaq.Channels.WebBridge}
}
```

The string `"email:smtp"` is mapped to the `:email` key before lookup. For `:web`, connection details are always `%{}` — delivery is via PubSub only.

### Outbound message formatting (Channels concern)

Outbound formatting is owned by Channels and applied at the `Zaq.Channels.Api`
boundary before transport delegation to bridge callbacks.

For final Agent messages carrying canonical `metadata[:tool_calls]`, this boundary
also derives public `metadata[:tool_steps]` on the bridge-facing delivery copy via
`Zaq.Contracts.ToolStep.project/1` — the same projector used by live Agent Status
updates. Engine finalization has already received the original private invocation
evidence; the internal message/event is not destructively sanitized or replaced.
Channels does not interpret native tool results or maintain invocation state.
Messages without canonical tool calls retain their previous metadata shape.
Adapter-specific step translation/rendering remains downstream work.

- Delivery path: `:deliver_outgoing` -> `MessageFormatter.format_outgoing/1` -> `bridge.send_reply/2`
- Upsert/edit path: `:upsert_message` -> `MessageFormatter.format_outgoing/1` -> `bridge.upsert_message/3`

Status upserts carry canonical `assistant_message_id` separately from request
correlation and provider edit handles. Agent.Status and Channels.Events preserve
the selected Engine UUID, and the Channels API includes it in the adapter-facing
request. `status_message_id` still supplies the existing provider `message_id`
used for edits; integer and string provider handles remain opaque. A canonical
assistant UUID must not replace a provider post ID. Before an answer root is
selected, progress may remain request-scoped without assistant correlation.

Formatting is configured per provider in `config :zaq, :channels` through
`message_format`, and optionally `message_formatter`:

```elixir
config :zaq, :channels, %{
  mattermost: %{
    bridge: Zaq.Channels.JidoChatBridge,
    adapter: Jido.Chat.Mattermost.Adapter,
    ingress_mode: :websocket
    # markdown-capable channel: no formatter needed
    # message_format: nil
  },
  email: %{
    bridge: Zaq.Channels.EmailBridge,
    message_format: :html
  },
  web: %{
    bridge: Zaq.Channels.WebBridge,
    message_format: :plain_text
  },
  telegram: %{
    bridge: Zaq.Channels.JidoChatBridge,
    adapter: Jido.Chat.Telegram.Adapter,
    message_format: :html,
    message_formatter: {Telegex.Marked, :as_html}
  }
}
```

Supported values:

- `nil` / unset / `:none` -> keep body unchanged
- `:plain_text` -> markdown source rendered through `Earmark` then converted to text
- `:html` -> markdown source rendered through `Earmark` and delivered as HTML
- `:markdown` -> body kept as markdown and stamped in `metadata.format` so the
  provider adapter can render it

Only these three formats cross the bridge. How a platform renders them is the
adapter's business: `jido_chat_telegram`, for one, maps `:markdown` onto Bot API
10.1 rich messages because Telegram's `sendMessage` parse modes cannot express
tables. Adapter-specific format names must never appear in this config.

Note that `:markdown` still has to be declared — with no `message_format` the
formatter stamps nothing, the bridge forwards nothing, and the adapter falls back
to an unparsed send.

If `message_formatter` is configured as `{Module, function_name}`, it is called
with arity 1 (`function_name.(body)`) and takes precedence over the default
`message_format` formatter.

Custom formatter errors are not swallowed.

When formatting is applied, `MessageFormatter` also stamps the canonical outbound
format hint in `Outgoing.metadata[:format]`:

- `:plain_text` formatting -> `metadata[:format] = :plain_text`
- `:html` formatting -> `metadata[:format] = :html`
- no-op formatting (`nil` / unset / `:none`) -> no format hint key is set

`Zaq.Channels.JidoChatBridge` relays this canonical `:format` hint in outbound
adapter opts for create/edit flows without provider-specific mapping. Adapter
packages are responsible for mapping canonical `:format` values to transport-
specific fields (for example Telegram `parse_mode`) when supported.

`sync_config_runtime/2` calls `bridge.start_runtime/1` or `bridge.stop_runtime/1` on the bridge if the function is exported. This is how the Supervisor delegates lifecycle to the bridge.

### Conversation Agent Eligibility

Conversation-channel routing only selects agents that are both:

- `active == true`
- `conversation_enabled == true`

Selection is enforced by `Zaq.Engine.IncomingMessageRouting` via agent eligibility lookup.

Implication:

- `conversation_enabled = false` means the agent is BO-only (not selectable from conversation channels).

See also: [Architecture → Configured Agent Runtime Lifecycle](../architecture.md#configured-agent-runtime-lifecycle).

---

## Bridge Behaviour

All channel bridge modules must implement `Zaq.Channels.Bridge`.

Required callbacks:

- `to_internal/2` — maps adapter payload to canonical `%Incoming{}`
- `send_reply/2` — delivers canonical `%Outgoing{}` through the transport

Optional callbacks cover runtime/lifecycle and provider extras (`start_runtime/1`,
`stop_runtime/1`, typing/reaction callbacks, profile/DM helpers, etc.).
Bridge also owns the option-aware `start_runtime/2`, `sync_provider_runtime/2` and
`build_runtime_specs/2` lifecycle contracts. A connector is a configuration map;
shared services use the explicit `{:provider, provider}` target. Supplying options
does not change target meaning. Legacy connector overrides are preserved by defaults,
while bridges needing option-aware connector behavior can override the additive
callbacks. CommunicationBridge routes targets/options without owning those contracts.

Shared routing helpers pass normalized incoming envelopes to Engine admission.
Engine persists the prompt before Agent execution and finalizes the outcome before
delivery; bridges do not write whole exchanges.

---

## Jido Chat Bridge

`Zaq.Channels.JidoChatBridge` is the provider-facing bridge for the `jido_chat` adapter family (Mattermost, Telegram, Discord, etc.).


### Shared adapter extension contracts

The bridge consumes core-owned `Jido.Chat.Authentication.Request` and
`Jido.Chat.Storage.Request` through the existing single `sink_mfa`. Public ingress
rejects both types. Authorized private requests execute synchronously before
serialized State routing, preserving storage reentrancy during outbound calls.
The existing Engine confirmation and credential-document Actions remain the
persistence and authorization owners; envelope types/references do not grant access.

Optional `Jido.Chat.Adapter` wrappers own delegation for provider infrastructure,
connection preparation, stable opaque identity, delivery options, and explicit
logout. Legacy adapters keep their existing listener/options behavior. The base
Bridge delegates connection details to its configured bridge. Host code forwards
adapter option maps without interpreting transport profiles or storage layouts.

### Connector listener settings

`Zaq.ConnectorConfig.Settings.defaults/1` owns initial provider settings; the provider
registry contains bridge, adapter and ingress-mode wiring. Engine applies defaults
through `ChannelConfig.create/2`, including upsert insertion and authentication
confirmation. Missing nested keys are filled; supplied values win. Providers without
a defaults clause receive an empty map.

During edits, the canonical changeset preserves saved values for defaulted keys
unless explicitly replaced. Engine also protects
[paired identity and credential metadata](engine.md#connector-credential-documents).
User-owned settings retain their replacement semantics.
Persisted settings use string keys. Shared projections resolve absent legacy values
at runtime without a backfill; explicit malformed values are not silently replaced.
Adapters validate transport options. The bridge forwards the connector's
`settings["jido_chat"]["ingress"]` without interpreting provider storage or profiles.

Saving and synchronizing changed ingress settings restarts the listener through the
shared lifecycle. Changing only reply policy refreshes handlers. Changes to defaults
in code affect connectors with absent keys; reload affected runtimes on deployment.
Provider-specific defaults and startup precedence follow the adapter contract.

### Connector reply policy

`ChannelConfig.settings["jido_chat"]["room_reply_policy"]` controls answer admission
for each saved connector. Accepted strings are `"default"` and
`"mention_required"`. Provider defaults may select the initial policy.
Engine's canonical changeset validates the policy and preserves explicit valid
choices on subsequent settings edits. Providers without a policy default retain
their existing behavior when the key is absent and can explicitly select either
policy. Invalid explicit policies reject writes;
malformed legacy runtime values conservatively require a mention.

The generic bridge uses normalized mention/DM facts. With `"mention_required"`,
unmentioned group messages still reach the sink and history capture, but cannot
trigger an answer through a message pattern. Mentions and DMs follow the existing
admission/routing paths; self/history filtering and thread-root handling remain
in effect. Changing only the saved policy and synchronizing the runtime refreshes
State's handlers without restarting its listener. The adapter does not decide
ZAQ's reply policy or discard unmentioned messages.

Lifecycle updates keep the existing Jido action route and source/attempt fencing.
Their `profile` field is an opaque connection identity, not a bridge-derived
transport profile. Adapter presentation is applied before sink acknowledgement.

### Bridge-Adapter Contract (mandatory)

- Bridge ingress callback name is standardized as `from_listener/3`.
- Bridges orchestrate only: convert to `%Incoming{}`, dispatch Engine incoming routing, deliver `%Outgoing{}`, persist conversation.
- Adapters own transport runtime details: connection lifecycle, listener child specs, and transport parsing.
- Bridges must request runtime specs from adapters (for example `adapter.runtime_specs/3`) instead of building listener specs directly.
- Adapter-specific callback names (for example `from_imap_listener/3`) are not allowed in bridge public APIs.

### Ingress flow

1. The adapter listener calls `from_listener/3` (configured as `sink_mfa` target).
2. `from_listener/3` ensures the runtime is started and looks up the `State` pid.
3. `State.process_listener_payload/4` branches on the payload shape:
   - **`%Jido.Chat.EventEnvelope{}`** — the adapter's normalized form for inbound events that `transform_incoming/1` has no representation for (reactions today). Handed straight to `Chat.route_event/4`, which classifies `event_type` and fires the matching handler. ZAQ does not classify or normalize these itself.
   - **anything else** — a raw message payload: transformed via `Jido.Chat.Adapter.transform_incoming/2`, annotated with transport mode, and processed through `Chat.process_message/5`.
4. The `Chat` handlers fire: `on_new_mention`, `on_new_message`, `on_subscribed_message`, `on_reaction`.
5. For qualifying messages, `handle_message_event/3` converts the `Chat.Incoming` to an `%Incoming{}` via `to_internal/2`, resolves the author's role IDs, calls `CommunicationBridge.route_incoming_message/4`, and delivers the `%Outgoing{}` result returned after Engine routing and Agent execution.

Both ingress modes converge on the handlers registered in `register_handlers/3`: webhook-mode providers (Telegram) reach them through `Chat.handle_webhook_request/4`, listener-mode providers (Mattermost, Discord) through `Chat.route_event/4`. Reaction normalization belongs to the adapter and `Jido.Chat.EventNormalizer` — never to ZAQ.

Non-DM thread replies are admitted according to the thread root: replies to a
ZAQ-authored root do not require another mention, while replies to roots authored by
other users require an explicit ZAQ mention. Root authorship is compared with the
configured bot user ID through the adapter's message-fetch contract. Missing bot
identity, unsupported lookup, inaccessible/deleted roots, and lookup failures fail
closed to mention-only handling. ZAQ participating later in another user's thread
does not change that policy. DM handling remains independent of root authorship.

### Reaction flow

Reactions are feedback, not a separate domain. The channel layer owns exactly one thing — turning a provider's emoji into a ZAQ rating — and from there the rating is indistinguishable from a back-office one.

1. `on_reaction` fires `JidoChatBridge.handle_reaction_event/2` with a `%Jido.Chat.ReactionEvent{}`.
2. Removals (`added: false`) are ignored.
3. `ReactionMapper.to_rating/2` maps the emoji to `1..5`, or `:ignored` for anything unmapped — this is the only reaction-aware step.
4. `CommunicationBridge.dispatch_message_rating/3` dispatches the engine's `:rate_message` action with `{:source, reference}` and a `rater_attrs` map. The reference carries trusted provider/connector identity, native channel ID, message source scope and external message ID. It reuses capture/delivery scope rules, including Telegram's chat-local IDs. Native room coordinates come from normalized Thread/ChannelRef handles before the event's fallback channel ID; handle prefixes are never parsed. **No bridge builds this event itself** — the seam is inherited by every bridge through `use Zaq.Channels.CommunicationBridge`.
5. `[:zaq, :chat_bridge, :reaction, :processed | :failed]` telemetry is emitted, mirroring the message path.

Nothing downstream of step 3 knows a reaction was involved. See `docs/services/engine.md` for the `:rate_message` contract.

For Mattermost, `ReactionMapper` maps `+1`, `thumbsup`, and `thumbs_up` to 5,
and `-1`, `thumbsdown`, and `thumbs_down` to 1. These shortcodes can be bare
or wrapped in a matched pair of colons, with an optional `_light_skin_tone`,
`_medium_light_skin_tone`, `_medium_skin_tone`, `_medium_dark_skin_tone`, or
`_dark_skin_tone` suffix inside the colons (for example, `:+1_medium_skin_tone:`).
Only complete shortcodes match: custom prefixes, invalid suffixes, trailing junk,
and unpaired colons remain ignored. This rating lookup does not change adapter
event normalization or other providers' shortcode mappings. Across providers,
Unicode thumbs up/down map to 5/1 when bare or followed by
exactly one standard skin-tone modifier (U+1F3FB–U+1F3FF). Repeated modifiers,
variation selectors, surrounding text and malformed sequences remain ignored.
Reaction removals and unrelated emoji still dispatch no rating.

### Outbound flow

Called by channels delivery routing (`Channels.Api` -> bridge-specific `send_reply/2`):

1. `send_reply/2` receives `%Outgoing{}` and connection details `%{url, token}`.
2. Resolves the adapter module for the provider.
3. Builds a `Jido.Chat.Thread` and calls `Chat.Thread.post/3`.
4. If `outgoing.metadata` contains an `"on_reply"` key, dispatches an Oban job for reply tracking (used by the Notification center).

### Thread watch management

- `subscribe_thread_reply/3` — starts a dedicated bridge runtime for `{channel_id, thread_id}` and calls `State.subscribe_thread/4`.
- `unsubscribe_thread_reply/3` — unsubscribes and stops the dedicated runtime.
- Thread bridge IDs are keyed `"#{channel_id}_#{thread_id}"`.

### Runtime lifecycle

- `start_runtime/1` — starts State + listener processes for a channel config.
- `stop_runtime/1` — stops them via the Supervisor.
- `runtime_specs/3` — returns `{state_child_spec, listener_specs}` for the Supervisor.

### Ingress modes

Configured per provider via `:ingress_mode` in app config. Supported values:

| Mode              | Behavior                                       |
| ----------------- | ---------------------------------------------- |
| `:websocket`      | Adapter starts a persistent WebSocket listener |
| `:gateway`        | Adapter starts a gateway listener              |
| `:polling`        | Adapter starts a polling listener              |
| Any other / `nil` | No listener started; ingress is push-only      |

### Configurable modules (testability)

All cross-service calls are overridable via Application env:

| Key                                 | Default                            |
| ----------------------------------- | ---------------------------------- |
| `:chat_bridge_pipeline_module`      | `Zaq.Agent.Pipeline`               |
| `:chat_bridge_router_module`        | `Zaq.Channels.CommunicationBridge` |
| `:chat_bridge_accounts_module`      | `Zaq.Accounts`                     |
| `:chat_bridge_permissions_module`   | `Zaq.Accounts.Permissions`         |
| `:pipeline_hooks_module`            | `Zaq.Hooks`                        |

When using the real modules, cross-node calls route through `Zaq.NodeRouter`.
Use `NodeRouter.dispatch/1` with `%Zaq.Event{}`.

---

## Jido Chat Bridge State

`Zaq.Channels.JidoChatBridge.State` is a GenServer that owns one `%Jido.Chat{}` struct per `bridge_id`. All mutations are serialized through this process to prevent race conditions across concurrent ingress sources.

### State shape

```elixir
@type state :: %{
  bridge_id: String.t(),
  config:    map(),
  chat:      Chat.t()
}
```

### Public calls

| Function                     | Description                                                                 |
| ---------------------------- | --------------------------------------------------------------------------- |
| `process_listener_payload/4` | Transforms + processes an adapter payload (serialized, `:infinity` timeout) |
| `subscribe_thread/4`         | Adds a thread key to `chat.subscriptions`                                   |
| `unsubscribe_thread/4`       | Removes a thread key from `chat.subscriptions`                              |
| `send_reply/3`               | Delegates to `JidoChatBridge.do_send_reply/2`                               |
| `send_typing/4`              | Delegates to `JidoChatBridge.send_typing/3`                                 |
| `add_reaction/6`             | Delegates to `JidoChatBridge.add_reaction/5`                                |
| `remove_reaction/6`          | Delegates to `JidoChatBridge.remove_reaction/5`                             |
| `refresh_config/2`           | Replaces config and rebuilds handlers, preserving runtime state             |

### Config refresh

`refresh_config/2` rebuilds the `Chat` struct (handlers, adapter) from the new config while preserving `subscriptions`, `dedupe`, `dedupe_order`, `thread_state`, and `channel_state` from the running instance.

---

## Email Bridge

`Zaq.Channels.EmailBridge` owns email communication behavior: IMAP listener
ingress, SMTP delivery, and lazy attachment materialization. SMTP sends use
`Zaq.Channels.EmailBridge.SmtpSender` (Swoosh/Mailer; SSL/STARTTLS,
`verify_peer`/`verify_none`, custom CA cert path; password decrypted via
`Zaq.Types.EncryptedString.decrypt/1`). Connection details are not required for
outbound sends — SMTP settings are read from `channel_configs.settings` for
provider `"email:smtp"`.

- `send_reply/2` — sends to `outgoing.channel_id` (the recipient address). Subject and html_body are read from `outgoing.metadata` (supports both atom and string keys).
- `from_listener/3` — generic sink callback for inbound email listeners; orchestration is bridge-owned.
- `to_internal/2` — resolves the provider adapter and delegates payload normalization to the adapter.
- `materialize_record/3` — materializes lazy IMAP attachment records from the exact source config.
- `start_runtime/1` and `stop_runtime/1` — resolve adapter runtime specs and delegate runtime lifecycle to `Channels.Supervisor`.

### Email IMAP Adapter

`Zaq.Channels.EmailBridge.ImapAdapter` owns IMAP-specific behavior:

- Runtime model: one `Zaq.Channels.EmailBridge.ImapAdapter.Listener` GenServer per selected mailbox (`state_pid` is `nil` for this runtime).
- Config shape: reads IMAP values from top-level config and `settings["imap"]` (`url`, `username`, `token`/`password`, `port`, `ssl`, `ssl_depth`, `timeout`, `idle_timeout`, `poll_interval`, `mark_as_read`, `load_initial_unread`, `selected_mailboxes`).
- Mailbox selection: if `selected_mailboxes` is empty, runtime can start but no listener children are created, so no inbound messages are consumed.
- Lifecycle: listener boot is `:connect -> optional initial unread fetch -> IDLE`; each `:idle_notify` fetches unseen messages, dispatches sink callback, optionally marks as read, then re-enters IDLE.
- Ingress fetch shape: metadata fetch requests `UID`, `ENVELOPE`, `BODYSTRUCTURE`, and `BODY.PEEK[HEADER]`. It does not fetch full `RFC822` and does not fetch attachment bytes during ingress.
- Body loading: after `BODYSTRUCTURE` parsing, the adapter fetches only the selected plain-text and HTML body sections with `BODY.PEEK[section]`, then decodes transfer encoding and charset for message content.
- Attachments: MIME parts that are explicit attachments, filename-bearing inline parts, or filename-bearing textual parts become lazy `Record` values in `Incoming.attachments`. Attachment bytes remain on the IMAP server until the signed handle is redeemed.
- Attachment identity: email attachment handles bind `provider: "email:imap"`, `channel_config_id`, `mailbox`, `uid_validity`, `uid`, `section`, transfer `encoding`, `source_author_id`, and display metadata such as name, MIME type, content id, and size.
- Attachment redemption: `CommunicationMedia` verifies the signed handle and actor, dispatches `:materialize_record`, and `EmailBridge` requires an enabled exact `email:imap` config. `ImapAdapter.download_attachment/2` validates locator fields, rechecks current `UIDVALIDITY`, fetches one `BODY.PEEK[section]`, decodes `base64` or quoted-printable bodies, and returns a materialized file `Record`.
- Attachment failures: deleted/disabled configs, provider mismatches, stale `UIDVALIDITY`, invalid or missing MIME sections, decode failures, and size-limit violations surface as materialization errors.
- Error handling: connect/fetch/IDLE re-entry failures and IMAP client exits are logged, client state is cleared, and reconnect is scheduled with `poll_interval` fallback (`30_000ms` default).
- IDLE timeout: `idle_timeout` defaults to `1_500_000ms` (25 minutes) when missing/invalid and is reused for each IDLE re-entry.
- Security: IMAP auth uses stored connector credentials (encrypted `channel_configs.token`), TLS is on by default (`ssl != false`), and logs avoid credential values.
- Security: parser stores `incoming.metadata["email"]["html_body"]` as raw, untrusted email HTML for fidelity. Renderers must treat it as untrusted content and only display it through explicit sanitization or strict isolation/sandboxing.
- Security: filenames, MIME types, text attachments, and HTML email content are attacker-controlled provider input. Treat materialized bytes and metadata as untrusted unless a downstream sanitizer or parser explicitly validates them.

#### Email Threading Semantics

- `thread_key`: stable conversation root key (`References` first id -> `In-Reply-To` -> `Message-ID`) used for conversation grouping.
- `thread_id`: nearest parent/current reply identity (`In-Reply-To` -> last `References` id -> `Message-ID`) kept in metadata for reply/header continuity.
- Parser stores both in `incoming.metadata["email"]`, plus the channel-agnostic
  anchor under `incoming.metadata["threading"]["anchor"]` (`message_id`,
  `thread_id` = references head or self, normalized `references` list) — built once
  at parse time so no engine reader interprets email headers.

#### Conversation identity (bridge callbacks)

`Zaq.Engine.Conversations` carries zero channel knowledge. Channel-specific grouping
lives behind two optional `Zaq.Channels.CommunicationBridge` callbacks, implemented
by `EmailBridge`:

- `conversation_key/1` — grouping key for an incoming email message
  (`email.thread_key` -> top-level `thread_key` -> `topic`/`subject` -> normalized
  RFC ids; `nil` lets the engine fall back to the author id).
- `outbound_conversation_key/2` — grouping key for an outbound-first send
  (`topic || subject`).

Every stamped identity also carries generic transport facts: `channel_config_id`,
`channel_id`, `thread_id`, and `participant_id`. Room-based communication providers
that do not supply a bridge grouping key are scoped by provider, connector
configuration, external channel, external participant, and stable external thread/root
id. A missing thread id is the channel-level conversation; it is distinct from every
thread in that channel. The external channel and thread remain separate persisted
fields so later aggregation does not require decoding a composite key. The first reply
in a newly observed thread starts fresh thread history; ZAQ does not copy the earlier
channel-level root post into it.

Engine resolves this stamped identity before Agent dispatch, persists the incoming user
message, and passes Agent only trusted conversation/message references. Channels does not
encode history identity into Agent runtime names and remains responsible only for transport
identity and delivery.

The `CommunicationBridge` dispatchers (`conversation_channel_type/2`,
`conversation_key/3`, `outbound_conversation_key/4`) resolve the bridge from
application config only — never `ChannelConfig` — so the persist path stays free of
DB lookups. Identity never crosses into the engine as a function call: inbound
envelopes are stamped with `metadata["conversation"]`
(`put_conversation_identity/2`, applied in `route_incoming_message/5`), and engine/agent callers ask the channels node
via the `:conversation_identity` event (`Zaq.Channels.Api`), passing either
`%{platform, topic, subject}` (identity map back) or `%{incoming}` (stamped
envelope back). Bridges without the callbacks resolve to `nil`; room-based providers
then use the generic channel/thread scope above, while email retains its bridge-owned
root key.

#### Outbound Threading (minting + delivery receipt)

`EmailBridge.send_reply/2` owns all outbound RFC 5322 threading mechanics:

- **Minting**: every email send carries its own `Message-ID`. The bridge honors a
  pre-minted id in the generic `metadata["threading"]` block (`"message_id"`,
  optionally `"references"`), otherwise mints one from the sending domain
  (`channel_configs.settings["from_email"]` of `email:smtp`, falling back to the
  default domain). gen_smtp would let the relay assign one ZAQ never learns, so
  ours must be the id that is delivered. The inbound-carried `threading.anchor`
  is never treated as a pre-mint — it describes the message being answered.
- **Parent resolution**: the parent comes from the opaque `Outgoing.thread_anchor`
  (string keys `"message_id"`, `"references"`, `"thread_id"`, resolved by the
  notification center from the notification log / conversations), else from
  `Outgoing.in_reply_to` (an inbound email being answered). `References` = ancestor
  chain + parent, capped via `EmailUtils.cap_references/1`.
- **Receipt**: on successful delivery `send_reply/2` returns `{:ok, receipt}` with
  `message_id`, `thread_id` (thread root), opaque `thread_metadata`, and the `anchor`
  map the notification center persists verbatim for the next send to chain onto.
  `thread_metadata` carries the same anchor under the channel-agnostic
  `"threading" => %{"anchor" => ...}` key (merged into the persisted message's
  metadata by `PersistMessageHistory`, so `Conversations.latest_thread_anchor/4`
  resolves it without email knowledge). The anchor is the single stored copy —
  no email-shaped duplicate is written.
  `Zaq.Channels.Api` normalizes bridges that return plain `:ok` to `{:ok, %{}}` so
  the `deliver_outgoing` response contract is uniform.

#### SMTP Configuration (env vars)

| Variable        | Default           | Description                    |
| --------------- | ----------------- | ------------------------------ |
| SMTP_RELAY      | —                 | SMTP server hostname           |
| SMTP_PORT       | 587               | SMTP port                      |
| SMTP_USERNAME   | —                 | SMTP auth username             |
| SMTP_PASSWORD   | —                 | SMTP auth password             |
| SMTP_FROM_EMAIL | noreply@zaq.local | Sender email address           |
| SMTP_FROM_NAME  | ZAQ               | Sender display name            |
| SMTP_TLS        | enabled           | TLS mode: enabled/always/never |

### Shared email configuration helpers

`Zaq.ConnectorConfig.SmtpSettings` is shared by Engine, BO presentation and transport.
`Zaq.ConnectorConfig.ImapSettings.get/2,3` owns pure IMAP settings lookup;
`EmailBridge.ImapConfigHelpers` retains provider-local mailbox/listener normalization
and delegates its compatibility getter to the shared implementation. Engine never
depends on that provider-local module. `Zaq.ConnectorConfig.Settings` owns pure
stored-map projections; none of these shared helpers accesses Repo or credentials.

- `map_get/2` — looks up a settings key by string name, falling back to its atom equivalent. Handles the dual string/atom key formats that SMTP settings maps may contain (e.g., `"relay"` and `:relay` are both accepted).

---

## Web Bridge

`Zaq.Channels.WebBridge` serves the ChatLive web channel.

BO history retrieval dispatches the Engine-owned authorized `:display_history`
operation; it does not enrich the older unscoped message reader with private
execution evidence. The existing response `trace` carries public projected tool
values for ordinary readers and full persisted traces for current `admin` and
`super_admin` readers authorized by Engine. BO history ingress and its nested Engine
read are confidential; missing confidentiality is rejected at both role boundaries.
The projection is server-derived, never enabled by request flags. BO history no
longer carries obsolete metadata `tool_calls`; live runtime tool calls remain intact.
Live/final BO delivery preserves optional validated `tool_steps` snapshots
through the existing upsert and completion hops; omission retains the legacy
no-snapshot shape. Widget live step/edit and terminal events now relay the same
validated public snapshots, and widget canonical display history restores them.
The widget package owns conversion into UI steps and browser presentation; other
adapters retain their current presentation.

BO renders ordered tool activity above the answer with inline recorded durations.
While a step is running, a message-scoped browser hook shows approximate elapsed
time since first observation on that page, using a monotonic local clock. Normal
patches/reconnection preserve that observation origin; a genuine remount starts a
new estimate. Terminal snapshots stop the clock and show recorded duration only
when available; unmeasured `unknown` outcomes do not retain an estimated duration.
No browser timer or timestamp is persisted or used to determine execution outcome.

- `to_internal/2` — translates a normalized `Web.Message` and trusted `Web.Context` into canonical Incoming (`:web` for BO, `:web_widget` for widgets).
- `send_reply/2` and `upsert_message/3` — publish `{:web_response, adapter_event_name, %Web.Response{}}` using the trusted delivery descriptor, never a metadata-selected topic.
- ChatLive uses `ZaqWeb.Chat.BridgeClient` to dispatch normalized messages and commands to Channels through `:web_ingress`. WebBridge owns canonical Engine routing. BO agent selection remains transient `event.assigns["agent_selection"]` (`source: "bo_explicit"`) and is resolved by Engine before the event continues to Agent.

See [Web transport contracts](#web-transport-contracts) for initialization, history and semantic delivery.

---

## Supervisor

`Zaq.Channels.Supervisor` is the single Channels supervisor child of the application.
It uses `Supervisor` with `:one_for_one` and starts these children in order:

1. `Zaq.Channels.PeopleAuthRateLimiter` — failed-identification counters and config cache.
2. `Zaq.Channels.BridgeSupervisor` — `DynamicSupervisor` for provider infrastructure, bridge state, listeners and temporary pairing sessions.

`JidoChatBridge` requests shared provider children through
`Jido.Chat.Adapter.provider_child_specs/2` before loading saved connectors. Provider
runtimes use distinct registry IDs and can start before any connector is saved.
The static Channels parent contains no provider-specific children. Adapter packages
own transport infrastructure, storage readiness and recovery behavior.

All Jido listeners run under `BridgeSupervisor`. WebSocket, gateway and polling
listeners use `restart: :temporary`; linked-device listeners retain their adapter's
restart policy. Registered PIDs refresh after restart. Partial startup cleans up
started children and bridge state. The dynamic supervisor has a shared restart
budget, not a separate budget for each listener. Runtime stop retains credentials;
explicit logout follows the adapter cleanup contract.

A limiter-supervisor failure resets only its own local resources. Bridge restarts
preserve limiter counters and cache. Parent shutdown stops both subtrees.

The widget's shared `{WebWidget, opts}` and connector supervisors are dynamic bridge
children; neither the application nor the static Channels parent knows widget options.
The parent forwards startup options unchanged. Runtime synchronization routes the
explicit `{:provider, provider}` target to registered bridges before enabled
connector startup. WebBridge assembles common `host_options` and provider-keyed
`adapter_options` and supplies default PubSub. Bridge's common startup path starts
shared adapter children through the same tracked runtime/listener machinery as
connector children, under a distinct
provider runtime ID. WebBridge owns adapter resolution; transport policy
interpretation stays in the adapter. No adapter callback dispatch belongs to the base
Bridge or supervisor, and no provider-specific bootstrap flags are stored in the registry.
Only Channels nodes start widget infrastructure. Stopping the parent stops all subtrees.
See [WebBridge lifecycle](web-bridge.md#widget-runtime-construction).

### Process tracking

Runtime state is tracked per `bridge_id` in an ETS table (`:zaq_channels_listeners`):

```elixir
bridge_id => %{listener_pids: [pid], state_pid: pid | nil}
```

The static parent owns the table, created when it calls the dynamic child's
`start_link/1`. A dynamic-child restart clears old entries before bootstrap; a
parent restart destroys and recreates the table. Lookups return
`{:error, :not_running}` when the table is absent or the runtime has stopped.

### Public API

All functions remain on `Zaq.Channels.Supervisor` and delegate directly to
`BridgeSupervisor`. Bridge defaults and `:chat_bridge_supervisor_module` overrides
keep the same interface; runtime calls do not message the static parent.

| Function                | Description                                                              |
| ----------------------- | ------------------------------------------------------------------------ |
| `start_runtime/2,3`     | Starts State + listener children for a bridge ID; listeners default to `[]` |
| `stop_bridge_runtime/2` | Stops all children and removes ETS entry for a bridge ID                 |
| `lookup_runtime/1`      | Returns `{:ok, %{listener_pids, state_pid}}` or `{:error, :not_running}` |
| `lookup_state_pid/1`    | Returns `{:ok, pid}` or `{:error, :not_running}`                         |
| `start_listener/1`      | Convenience — delegates to `CommunicationBridge.sync_config_runtime/2`   |
| `stop_listener/1`       | Convenience — delegates to `CommunicationBridge.sync_config_runtime/2`   |

### Bootstrap

On every `BridgeSupervisor.start_link/1`, `load_initial_runtimes/0` queries
`ChannelConfig.list_enabled_by_kind/2` for retrieval and data-source configs whose
providers have a configured `:adapter`. It calls `CommunicationBridge.sync_config_runtime/2`
or `DataSourceBridge.sync_config_runtime/2` respectively. Base provider keys match
sub-providers such as `email:imap`.

`Zaq.NodeRouter` locates the channels node by calling `Process.whereis(Zaq.Channels.Supervisor)`.
This registration identifies the role, not child readiness. The limiter's config
fetch runs in its background worker and can dispatch to Engine while the parent
continues starting bridge infrastructure.

---

## Channel Config

Configuration persistence is owned by [`Zaq.Engine.ChannelConfig`](engine.md#connector-configuration-persistence).
The `channel_configs` table and identity FKs are unchanged. Legacy Channels
bootstrap/delivery/provider-only paths still call this schema locally; its namespace
move does not establish a Repo-free Channels node. Supplied email-save and archive
runtime events do not use those legacy persistence paths.

---

## Retrieval Channel

`Zaq.Channels.RetrievalChannel` (schema: `retrieval_channels`) represents a specific platform channel that ZAQ monitors. Each record links a platform channel ID to a `ChannelConfig`.

### Fields

`channel_config_id`, `channel_id`, `channel_name`, `team_id`, `team_name`, `active` (default `true`).

Unique constraint: `[channel_config_id, channel_id]`.

### Query functions

| Function                      | Description                                                         |
| ----------------------------- | ------------------------------------------------------------------- |
| `list_active_by_config/1`     | All active channels for a config ID                                 |
| `list_by_config/1`            | All channels (active and inactive) for a config ID, ordered by name |
| `get_by_config_and_channel/2` | Single channel by config ID and platform channel ID                 |
| `active_channel_ids/1`        | All active channel IDs for a provider string                        |

When `list_active_by_config/1` returns non-empty results, the listener is started with those specific channel IDs. When empty, the listener receives `:all` — it subscribes to all channels.

---

## Mattermost Admin

`Zaq.Channels.MattermostAdmin` provides admin operations for the Mattermost channel configuration UI. Backed by `Jido.Chat.Mattermost.Transport.ReqClient`. Not intended for bot ingress/egress.

| Function                 | Description                                         |
| ------------------------ | --------------------------------------------------- |
| `send_message/2`         | Sends a message to a channel (loads config from DB) |
| `fetch_bot_user_id/2`    | Fetches bot user ID via `/api/v4/users/me`          |
| `list_teams/1`           | Lists teams the bot belongs to                      |
| `list_public_channels/2` | Lists public channels for a team                    |
| `clear_channel/1`        | Deletes all posts in a channel (destructive)        |

---

## What's Done

- Communication bridge helpers with full provider API: `send_typing`, `add_reaction`, `remove_reaction`, `subscribe_thread_reply`, `unsubscribe_thread_reply`, `sync_config_runtime`, `test_connection`
- `JidoChatBridge` with ingress via `from_listener` / `sink_mfa`, outbound via `send_reply`, thread watch management, configurable ingress modes, and Oban-based on_reply dispatch
- `JidoChatBridge.State` GenServer with serialized message processing, config refresh preserving runtime state, and full reaction/typing delegation
- `EmailBridge` for IMAP ingress, SMTP delivery, and lazy email attachment materialization
- `WebBridge` for LiveView sessions via PubSub (with status callback support)
- `Supervisor` with ETS-backed runtime tracking and bootstrap on startup
- Engine-owned `ChannelConfig` with encrypted token storage and full query API;
  shared pure settings projections under `Zaq.ConnectorConfig`
- `RetrievalChannel` with active/all channel queries
- `MattermostAdmin` for UI-facing admin operations
- Canonical `Incoming` / `Outgoing` structs as the adapter boundary contract
- All cross-node calls routed through `Zaq.NodeRouter`
