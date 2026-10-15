# WebBridge protocol

This is the detailed owner for the implemented **widget version 2 / BO version 1** protocol.
The adapter-facing values are [`Zaq.Channels.Web.*`](../../lib/zaq/channels/web/),
not Engine `Incoming`/`Outgoing`. [`WebBridge`](../../lib/zaq/channels/web_bridge.ex)
validates/translates them and preserves existing Engine admission/finalization.
See [Channels](channels.md), [Engine](engine.md) and the
[adapter installation handoff](../guides/web-widget-integration.md).

## Entry points and versioning

| API | Contract |
| --- | --- |
| `Message.new(map)` | `{:ok, Message.t()}` or `{:error, reason}` |
| `Command.new(map)` | `{:ok, Command.t()}` or `{:error, reason}` |
| `Context.new(actor_or_nil, keyword_opts)` | Trusted Context construction; never decode this from browser data |
| `Delivery.new(map)` / `Delivery.bo(topic)` | Trusted destination/event descriptor; the BO convenience builder returns the struct directly |
| `Response.new(map)` | Sanitized semantic Response construction |
| `WebBridge.from_listener(config, payload, context: context)` | Shared ingress; the configured widget runtime uses the config-bound sink below |
| Channels Event action `:web_ingress` | Request `%{payload: Message_or_Command, context: Context}`; Event actor must agree with trusted Context |

Constructors accept known atom/string map keys and reject unknown fields.
Required identifiers are nonblank strings, trimmed and bounded to 255 bytes.
Invalid optional identifiers normalize to nil. Message/Command are not versioned
wire envelopes. Widget Delivery defaults to `protocol_version: 2` and rejects version 1;
BO Delivery remains version 1. Response supports both versions, defaulting to 1 for
BO callers; WebBridge explicitly produces version 2 for widgets. Use the published constructors rather than
an independent payload schema. Inbound message edit is unsupported. Legacy BO flat
payloads and standalone result/status tuples are no longer accepted.

## Message

| Field | Requirement / type |
| --- | --- |
| `request_id` | Required identifier for correlation |
| `message_id` | Required transport message identifier |
| `content` | Required nonblank string, trimmed, at most 100,000 bytes |
| `timestamp` | Required `DateTime` in `Etc/UTC`; adapters decode wire timestamps |
| `channel` | Required routing selector identifier, not authority to choose an agent |
| `mode` | Required `:async` / `:sync`, or matching strings |
| `conversation_id` | Optional existing conversation identifier |
| `author_id`, `author_name` | Optional identifiers; widget author ID, if present, must equal the trusted sender |
| `attachments` | List, default `[]`; canonical media handling remains Channels-owned |
| `prompt_context` | Optional nonblank string, at most 100,000 bytes; ordinary first-message user history |

Trusted actors, capabilities, destinations, configuration IDs, supplied history and
executable dispatch choices are not Message fields.

### Message to Incoming mapping

`content`, author name, message ID and attachments map to the corresponding canonical
fields. The timestamp becomes `routing_context.provider_sent_at`; request ID remains
correlation metadata. BO uses provider `:web`, the supplied channel coordinate and its
authenticated actor/Person. Widget ingress uses provider/platform `web_widget`, the
trusted sender as author and `conversation_type: :one_to_one`; Engine's existing
communication policy selects Direct history. Its `channel` becomes `topic_id`, while
Engine preparation establishes/restores the private native chat coordinate. Trusted
configuration, conversation and serialized Delivery references travel in routing
context; returned runtime metadata cannot overwrite the destination.

For a first actual widget question, Engine composes existing conversation creation,
optional ordinary `add_message/2` context persistence and canonical capture, then
normal routing/admission/finalization. Context is visible user history, not a privileged
prompt type or a separate Agent run. It may trigger normal title generation. Resume
does not reseed. The adapter retains initial context until the first actual Message.
The closed Engine boundary delegates sender readiness to IdentityResolver and input
binding/restoration to Conversations. The binding resolver is shared with ordinary
admission; no widget-specific conversation owner or execution record is introduced.

## Commands and restoration

Command fields are required `request_id`, required `type`, optional `conversation_id`
and `params` (map, default `%{}`). Types are `:conversation_init` / `"conversation.init"`
and `:conversation_history` / `"conversation.history.request"`. Adapter wire
`widget.init` maps to the shared init type; there is no widget-only command struct.
Executable action/module/function/MFA, actor, bypass and delivery keys are forbidden
inside params, including nested values. Commands never enter the Agent pipeline.

Initialization may include `params.stylesheet_url`: an optional absolute HTTP(S)
URL of at most 2,048 bytes, without credentials, whitespace or control characters.
Local paths, `zaq://`, protocol-relative URLs and other schemes are rejected.
Styling is instance-scoped; the adapter loads the URL in the browser, not through
ZAQ fetching/proxying. It is not persisted or sent to the Agent. History commands
cannot supply styling. HTTPS is recommended; browsers may block HTTP stylesheets
on HTTPS pages. Both constructors and ingress validate manually constructed commands.

| Consumer / operation | Response |
| --- | --- |
| BO init | `:conversation_initialized`; conversation ID and `created`, optionally `replaced_missing_id` |
| Widget idle init | `:widget_initialized`; `created: false`, readiness, no new conversation ID |
| Widget resume init | Same initialized type with an authorized existing conversation ID; never replacement creation |
| Widget history | `:conversation_history`, payload `%{messages: ordered_public_messages}` |
| BO history | Same semantic type with BO conversation/message projections, including its UI ratings/info fields |
| Command failure | `:error`, payload `%{code: stable_code}` |

Widget history/resume resolves sender through connector-scoped People identity and
requires literal Person/configuration ownership, an existing Direct transcript and
canonical grants. Unknown, deleted, unbound or inaccessible chats fail without a BO
fallback. `sender_id` is **not** a ZAQ Person primary key or a People bearer.

Widget history params are `limit` (default 50, maximum 100), `after_position` and
`up_to_position`, using the existing canonical reader's position bounds. Results are
ascending public message projections, not execution records. Conversation IDs are
not transcript IDs; use the returned positions for pagination. See the canonical
history contract in [Engine](engine.md), not generic conversation reads.

BO retains its named missing-conversation fallback. ChatLive owns welcome presentation
and persists the fixed welcome only after newly-created BO init. Listing/deletion,
ratings, title subscriptions and source previews retain existing role actions.

## Trusted Context and adapter security

Context opts are `consumer`, `capabilities` (default `[]`), `delivery`,
`selected_agent_id`, `content_filter` (default `[]`), `history` (default `%{}`),
`sender_id` and `channel_config_id`. BO requires an authenticated actor map for ingress;
its only supported explicit capability is `:skip_permissions`. Nil actor grants no
capability. BO's agent/filter/history inputs remain trusted server state.

Widgets use `Context.new(nil, consumer: :widget, sender_id: verified_sender,
channel_config_id: connector_id, delivery: trusted_delivery)`. They require a verified
sender and positive configuration ID at ingress, no bypass capability, no explicit
agent, no supplied history and no content-filter overrides. Delivery consumer/config
must match. Readiness also verifies provider `web_widget` and enabled/unarchived config.

The external adapter verifies parent-app identity/session **before** supplying sender
identity and controls endpoint, iframe/origin protections and subscriptions. ZAQ then
performs its separate People/routing/chat/history authorization. Neither constructors
nor browser-supplied IDs authenticate a sender. Never put shared secrets, raw identity
proofs or credentials in browser configuration, canonical routing context or history.

### Verified sender profiles

Adapters may supply optional trusted `Context.profile_context` containing
`%{sender_id: verified_sender, channel_config_id: id, profile: profile}`. The profile
has optional `full_name`, `email` and `phone` keys (atoms or strings). It originates
from authenticated parent assertions; browser message fields cannot override it.
The adapter carries it with initialization and message preparation, without an
independent profile cache or replicated store.

The existing Channels `:fetch_profile` event carries the resolved connector ID to
WebBridge, together with opaque request-scoped profile context. Engine and
IdentityResolver forward that context without interpreting profile fields. The bridge
validates sender/configuration binding, pins `channel_id` to the verified sender,
and maps `full_name` to discovery's `display_name`. IdentityResolver
uses its existing enrichment and `People.find_or_create_from_channel/2` for missing
or incomplete senders, including initialization. Complete identities use the existing
link without profile fetching. Missing profiles retain identifier-only discovery;
invalid supplied profiles fail discovery. Other bridges retain their provider API
lookup. Profile-bearing Engine and Channels events are confidential to exclude
observer broadcasts. Context travels across node hops, never in process-local lookup state.

People owns email/phone matching, channel linking, backfill and atomic conflict
handling. Profile email creation still requires a resolvable email connector under
the [People email contract](engine.md#canonical-person-email). Messages carry the
existing normalized `Incoming.person`; no profile payload is added to Incoming
or the web message protocol. People remains the sole durable profile store.

## Delivery, responses and lifecycle

Delivery fields are required `consumer` (`:bo` / `:widget`), required `topic`,
`events` (semantic-to-adapter-name map, default `%{}`), optional `protocol_version` (widget 2 / BO 1) and
optional positive `channel_config_id` (required for widget scope). Event names are
nonblank strings or nonboolean/nonnil atoms. Unknown semantic keys are rejected.
Widget messages require mappings for typing, create, edit, step, complete, failed and
error before creating the chat. Command/acceptance responses are returned directly
and must also be encoded by the adapter; they do not depend on PubSub subscription.
The bridge binds optional trusted `conversation_id` and `message_id` to the descriptor
after preparation. Only Channels interprets these correlation fields; generic role
code carries the serialized reference opaquely. A reserved transport ID does not
promise that an assistant message will be produced.

Responses contain the consumer's `protocol_version`, required `request_id`, required semantic
`type`, optional `conversation_id`/`message_id` and `payload` map (default `%{}`). Public payload
projection precedes recursive rejection of actor/credential/token/private execution
fields. Widget finals exclude BO traces, raw tool calls and agent metadata.

| Semantic type | Widget payload / interpretation | BO mapping |
| --- | --- | --- |
| `:widget_initialized` | Ready/resume details; `created: false` | Not BO initialization |
| `:conversation_initialized` | BO init details | Direct command result |
| `:conversation_created` | First async receipt: `accepted: true`, `created: true`, new conversation ID | Not BO widget receipt |
| `:conversation_history` | `messages` public ordered history | Direct command result |
| `:typing` | `active: true` / `false` | Not emitted by BO descriptor |
| `:message_create` | Empty assistant `body`, stable transport ID | Not emitted by BO descriptor |
| `:message_edit` | Full current `body`; replacement snapshot, never append-only delta | `:status_update` |
| `:message_step` | Fixed public `label`, `kind: :activity`, `state: :running`, `step_id`; no raw reasoning | Not emitted by BO descriptor |
| `:message_complete` / `:message_failed` | Public `body`, `error`, persisted assistant/user references; sync return adds `created` | `:pipeline_result` |
| `:status` | Resumed async acceptance: `accepted: true`, `created: false`; internal activity is projected into steps | `:status_update` |
| `:error` | Safe `code`; timeout also includes `outcome: :unknown` | `:pipeline_result` for delivery errors |

PubSub shape is `{:web_response, adapter_event_name, %Web.Response{}}`. Widget adapter
names are configurable; the handoff shows `response.message.create/edit/step/complete/failed`
and `response.typing/error`. BO preserves its old event-name atoms inside the **new**
normalized tuple. BO finals expose `body`, `user_content`, `sources`, `confidence_score`,
`error`, `error_type`, `assistant_message_id`, `user_message_id`, `agent`, `model`,
`latency_ms`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `trace` and
`tool_calls`. List fields default to empty lists; unavailable optional scalar/reference
fields may be nil. BO history conversations project `id`, `title`, `status`, `inserted_at`
and `updated_at`. BO history messages project `id`, `role`, `content`, `sources`,
`confidence_score`, `model`, token counts, `latency_ms`, `metadata`, `trace`, `ratings`
and `inserted_at`; rating fields are `id`, `rating`, `reason` and `comment`.
These BO information fields are not the widget's public projection.

Submission and assistant-message lifecycles are independent. Async returns a
creation/status receipt with `accepted: true`, the request/conversation IDs and **no
assistant message ID**. This acknowledges submission dispatch, not native input
consumption, generation or a promised answer. Workflow-only inputs, provider replays
and accepted steering can produce no independent assistant message. An additional
accepted status may use `response.status` when no explicit status mapping exists.

Async responses go directly to the adapter's existing authorized subscription; there
is no per-message transport owner or relay. Native `request_started` is projected
through Agent's existing Status boundary to typing active → assistant create. Only
then do stream edits and safe activity steps follow. Generic pre-admission statuses
create no placeholder. A final persisted answer without a streamed start first creates
its public assistant message; an early failure instead produces a request-scoped
`:error` with no assistant ID. Queued acknowledgements are never empty completions.
Engine/Agent retain admission, steering, runtime ownership, synchronization and
finalization. They do not interpret widget destinations or public event names.

Transport assistant IDs stay stable across create/edit/step/terminal; persisted
assistant/user IDs remain separate payload references. The adapter independently
correlates each stream and ignores duplicate/late terminal regressions. A receipt
does not keep a spinner waiting for an answer that may never exist. Native generation
completion is not public completion: final delivery follows Engine persistence and
confirmed history synchronization through the normal Channels return hop.

Sync uses a bounded caller-side `Web.SyncReply` subscription, returning one terminal
Response **or a no-answer submission acknowledgement**, with no duplicate terminal at
the original adapter destination. `:web_widget_sync_timeout_ms` defaults to 30,000
milliseconds; positive values are bounded to 900,000 milliseconds. The obsolete async
owner timeout is removed. Wait cleanup never cancels accepted Engine work, including
when the caller disconnects. Timeout is an unknown outcome, not permission to retry.
PubSub is best effort, not durable replay or exactly-once execution. Reconnect/timeout
recovery uses authorized canonical history.
Subscribe to an authorized pre-creation destination before the first question; wait for
its conversation ID before submitting subsequent questions to the same chat.

## Errors

Constructors/ingress may return `{:error, {:invalid_field, field}}`, `{:unknown_fields, keys}`
or forbidden-key errors. Trusted context errors include `:missing_web_context`,
`:invalid_web_context`, `:unauthorized` and `:forbidden_widget_options`. Widget messages
without delivery fail with `:missing_delivery_descriptor`; incomplete mappings fail
with `:incomplete_event_mapping`. Do not infer successful acceptance from these errors.

Command error `code` preserves an atom reason or the atom tag of a two-element tuple,
discarding tuple details; other reasons become `:operation_failed`. Identity/configuration
failures use `:unauthorized`; private missing/inaccessible/unbound chats use
`:conversation_not_found`. Service availability failures can use `:engine_unavailable`,
`:conversation_unavailable` or `:history_unavailable`. Accepted work can later produce
`:message_failed`; transport timeout produces `:error` / `:timeout` / unknown outcome.
Do not expose raw internal error tuples, credentials or execution traces on the wire.

## Widget runtime construction

Configure `:zaq, :channels, :web_widget` with `bridge: Zaq.Channels.WebBridge` and a
trusted `adapter` implementing the transport-neutral embedded web
adapter contract declared by [`WebBridge`](../../lib/zaq/channels/web_bridge.ex):
`build_runtime_specs(config, hooks)` and optional `installation(config_or_id, base_url, opts)`.
Return from `build_runtime_specs/2`
`{:ok, {state_child_spec_or_nil, listener_specs}}` or `{:error, reason}`. Existing
BridgeSupervisor starts children, rolls back partial startup and follows automatically
restarted PIDs. Start is idempotent; unchanged enabled config preserves runtime, changes
restart, and disable/removal tears down using the configuration snapshot. BO needs no
widget runtime. Startup/construction errors are returned, not success receipts.

Provider registration points directly at the upstream `WebWidget.HostAdapter`.
WebBridge resolves the adapter through `Bridge.provider_config/2`; ZAQ has no concrete
widget adapter implementation. The upstream implementation returns a stable
`WebWidget.Connector` child, not a generation-bound runtime.
Before loading enabled connectors, ordinary runtime synchronization uses an explicit
`{:provider, provider}` target and unchanged trusted startup options. Connector maps
remain connector targets whether options are supplied or not; bare provider names
retain legacy database lookup. Bridge owns the optional lifecycle callbacks and
common startup/result handling. WebBridge extends `build_runtime_specs/2` to request
its adapter's optional `infrastructure_child_specs/1`; Bridge starts those specs
through the existing runtime/listener machinery under a separate
`provider:<provider>` runtime ID. The package starts once; disabling a connector
stops only that connector runtime. There is no separate infrastructure-start loop
or CommunicationBridge infrastructure callback. Concurrent runtime starts serialize
on a node-local runtime-ID lock; child tracking and rollback are shared.
The adapter-facing callbacks declared in WebBridge describe its external dependency,
not a second bridge lifecycle behaviour. Legacy connector callback overrides remain
in effect through option-aware defaults; bridges may override the additive callbacks
when they need option-aware connector behavior.
An absent callback means no shared infrastructure, not a special provider flag.
`Channels.Supervisor` forwards startup options unchanged; WebBridge supplies the
default PubSub when assembling common `host_options` and provider-keyed
`adapter_options`. Trusted composition supplies these as child startup options. The widget's shared
`{WebWidget, opts}` child and stable connector
children all belong to the dynamic bridge subtree. Connector subtrees rebuild their runtime after
infrastructure loss, with bounded retry and fresh configuration. ZAQ uses its ordinary
DynamicSupervisor and existing replacement/disable lifecycle, without package-specific
recovery coordination. A live connector PID establishes ownership, not readiness.

Hooks contain exactly shared Message/Command/Context/Delivery/Response modules and
`sink_mfa: {Zaq.Channels.WebBridge, :from_adapter, [%{id: config.id}]}`. The upstream
adapter derives widget identity and presentation from resolved config. Invoke the sink with
`payload, [context: verified_context]`. It accepts shared structs and a matching
widget Context, then dispatches closed Channels `:web_ingress` through NodeRouter.
Event data cannot replace bound config or choose a builder module.

Persisted presentation/embedding settings are `display_name` (nonblank, ≤200 bytes)
and `allowed_domains` (≤100 exact HTTP(S) origins without
paths/wildcards/userinfo/query/fragment). `stylesheet_url` is init-only and is
rejected in persisted settings. Server-owned `key_rotated_at` records key generation.
Saving an older connector removes its obsolete persisted `stylesheet_url` while
preserving unrelated settings.
Absent settings may be stored for disabled legacy connectors; runtime construction
must satisfy the installed adapter's requirements, including an empty origin
allowlist. A separate `widget_id` setting is rejected. ZAQ now mounts the included
package's router and scoped socket on its host endpoint; it does not start a separate
widget endpoint. Follow the [handoff](../guides/web-widget-integration.md)
for BO references, constructor examples, executable fixtures and real-package acceptance.

Engine persistence validates desired settings through the pure
[`WidgetSettings.validate/1`](../../lib/zaq/connector_config/widget_settings.ex)
contract. The upstream adapter validates runtime inputs; neither role calls the other
role's runtime or duplicates the package's transport policy.

### Connector authentication and cookie settings contract

**Included candidate supports connector-owned settings and scoped cookies.** The
ZAQ form, settings projection and runtime configuration support this extension.
The package revision and host acceptance steps are documented in the
[installation guide](../guides/web-widget-integration.md#included-candidate-package).
Saving a value alone does not establish that its runtime synchronization succeeded.
Adapter work is tracked in [web_widget #10](https://github.com/www-zaq-ai/web_widget/issues/10)
and [#12](https://github.com/www-zaq-ai/web_widget/issues/12); contract coordination
is tracked in Beadwork `zaq-yx7`, with host implementation in `zaq-kgw` and `zaq-m0a`.
These requirements extend the existing settings
and runtime boundaries; they do not introduce another configuration store.

Persist these string keys in `channel_configs.settings`. Use the same keys in the
confidential management request and allowlisted BO snapshot. The trusted adapter
receives them in `config.settings` at connector startup; they are not duplicated into hooks.

| Key | Value contract | Default for a new connector |
| --- | --- | --- |
| `identity_issuer` | UTF-8 string, 1–255 bytes, no leading/trailing whitespace | `zaq_issuer` |
| `identity_audience` | UTF-8 string, 1–255 bytes, no leading/trailing whitespace | `zaq_audience` |
| `same_site` | Exactly `"None"`, `"Lax"` or `"Strict"` | `"None"` |

Issuer/audience are exact, case-sensitive JWT `iss`/`aud` expectations, not URLs
or secrets. The parent backend signs with the same effective values. Present blank,
nil, invalid or wrongly typed values reject; they must not silently choose a fallback.
Engine persistence uses the pure `WidgetSettings` contract. A partial save such as
enable/disable preserves omitted settings; new connectors persist the defaults.

The included candidate requires all three keys explicitly at runtime and rejects
missing values. It provides **no** legacy application/endpoint fallback, superseding
the earlier planned adapter inheritance contract. Existing records retain omissions
on unrelated saves; an administrator must explicitly provision the previous actual
identity expectations and cookie policy before re-enabling/upgrading them. Follow
the [legacy upgrade guide](../guides/web-widget-integration.md#legacy-connector-upgrade).
Do not silently fill missing values, relax cookies to `"None"`, or claim an omitted
value is operational. BO reports actual installed values/source or unresolved.
Resolved identity options, effective cookie policy, verifier selection, PubSub and
endpoint selection remain server-owned. Browser input cannot override them.

`"None"` requires a Secure cookie over HTTPS. The adapter must enforce the requested
policy on widget-scoped session cookies and keep the session compatible with the
existing LiveView handshake. It must not relax ZAQ's BO session cookie or let widgets
with different policies overwrite each other's cookies. A cookie scoped only to
`/channels/widget/:id` does not reach BO's `/live`; the included package uses the
matching `/channels/widget/:id/live` mount for its **single** widget LiveView connection.
Copying attributes onto the shared BO cookie does not establish isolation. The
package owns widget bootstrap, session and CSRF verification; BO remains on its
unchanged session/transport. Host-mounted and package-endpoint modes must document
and verify the same session contract.

Settings may be saved as desired configuration but must not be presented as applied
without verification. Report `cookie_policy_unsupported` or
`cookie_policy_mismatch` through the readiness contract below. `SameSite=None` does
not guarantee operation when a browser blocks third-party cookies. Explicit HTTP
development exceptions require a separately documented policy, not a silent weakening
of the production `"None"` contract. Configuration changes reuse the existing runtime
refresh and session-generation invalidation path.

### Adapter readiness callback contract

**ZAQ invocation/validation and included candidate transport probing implemented.** Tracked in
[web_widget #16](https://github.com/www-zaq-ai/web_widget/issues/16).
The optional `ingress_status(config, opts)` belongs to the same dynamically selected
adapter as runtime construction. WebBridge supplies `timeout_ms: 2_000` and enforces
that total deadline. The callback returns `{:ok, %{status: state, summary: text, ...}}`
using `:ok`, `:pending`, `:error`, `:unknown` or `:disabled`. Adapter observations are
already safe for BO; they must not contain secrets, private runtime values or exceptions.

`WebWidget.HostAdapter` owns the package-specific five checks, closed reason/value
schema, desired-versus-installed comparison and verification scope. ZAQ neither
reimplements nor interprets that algorithm. The raw `RuntimeBuilder.status/2` API is
upstream compatibility, not the host bridge contract. Missing status support yields
Unknown. The callback is read-only and requires no authenticated visitor or conversation.

Callback-level failures return `{:error, reason}` where reason is exactly
`:invalid_request`, `:check_timeout` or `:check_failed`. ZAQ bounds the complete
invocation to 2,000 ms, handles exceptions/exits, validates the common result envelope,
and projects absent callbacks, timeouts, failures and malformed replies to
unknown with a safe explanation. Do not pass unbounded or raw diagnostics to BO.

Readiness version 2 is separate from the widget response protocol version 2.
The closed `verification` map requires `scope: :local`, `external_https: :not_checked`,
and `session_handshake: :verified | :not_checked`. The upstream adapter rejects external
verification claims or unknown/private fields; ZAQ relays those safe observations.
For proxy-only HTTPS, local readiness verifies installation, trusted proxy policy and
insecure-request rejection, not an external session handshake. BO uses the existing
**Ready** label and explains unchecked scope in the status details. The proxy may be down while local
readiness stays ready; a public URL alone proves neither HTTPS nor WSS reachability.
See the [proxy deployment guide](../guides/web-widget-integration.md#proxy-terminated-https-and-local-development).

In host-mounted mode, discover the endpoint with the matching scoped widget socket;
in package mode, check the package endpoint. A registered connector, loaded module or
living endpoint supervisor alone does not prove a listening WebSocket transport.
If a reliable local transport check is unavailable, return `:unknown` with
`transport_unverifiable`. This contract proves local readiness only, not public
proxy/TLS reachability, successful visitor authentication or endpoint security.

The existing Channels `:channel_ingress_status` event carries the adapter's result;
both BO surfaces reuse that result via NodeRouter. Disabled is a separate
Engine-owned configuration state: disabled connectors display Disabled without
probing or contributing to enabled-connector health. Enabled is never synonymous
with healthy. Readiness support is not an additional enablement prerequisite for
legacy adapters. Checks run asynchronously, refresh after lifecycle changes and
while the page is open, and discard stale results after disable/removal/replacement.

Acceptance must cover per-connector identity overrides/defaults/legacy values,
invalid values and partial saves; widget-scoped cookies and unchanged BO sessions;
zero-visitor readiness, stopped listeners despite registered runtimes, PubSub loss,
both endpoint modes, restart/recovery, absent callbacks, malformed/secret-bearing
results and timeouts. Actual browser WebSocket connection/reconnection tests remain
necessary for adapter acceptance; a GenServer-only fixture cannot establish it.

## BO configuration and installation

Channels → Communication → Web Widget uses
[`WebWidgetLive`](../../lib/zaq_web/live/bo/communication/web_widget_live.ex).
Engine's confidential `:widget_connector_settings` action authenticates the current
BO actor and invokes `ManageWidgetConnector` through `Jido.Exec`. Snapshots are
allowlisted and contain no keys or raw configuration schemas. Saves and key mutations
lock the exact unarchived `web_widget`/retrieval connector and check the lifecycle
revision. Agent choices write the existing connector-scoped `IncomingMessageRouting`
rule, not widget settings. Archival reuses `ConnectorLifecycle`.

Disabled configurations can be saved without an installed adapter. Enablement
requires global `system.global.base_url` and an adapter implementing both callbacks.
Adapter availability uses the existing `:channel_capability_snapshot` query with
explicit provider scope; it does not select a connector or inspect its credentials.
Connector health remains on `:channel_ingress_status`. A registered bridge alone
does not establish that its adapter is installed or supports construction/installation.
Configuration changes use confidential `:sync_channel_runtime` with resolved
before/after configurations. A saved result can have pending runtime synchronization;
it is not a rollback or confirmation that the endpoint is secure.

`installation(config_or_id, base_url, opts)` returns `{:ok, String.t()}` or `{:error, reason}`.
Engine authorizes the selected ID and resolves the global base URL; a confidential
provider-scoped Channels `:channel_installation` read resolves the configured bridge,
which delegates to its registered adapter's installation callback.
ZAQ accepts nonempty UTF-8 markup of at most 32,768 bytes and displays it as escaped,
copyable text, never executable BO markup. No signing secret is supplied to this callback.
Disabled connectors can request installation. There is no combined setup event.

### Trusted mount scope

WebBridge supplies `scope: "/channels"` as trusted adapter initialization input.
ZAQ uses the same literal in `web_widget("/widget", scope: "/channels")`,
`web_widget_api("/widget-api", scope: "/channels")` and
`web_widget_socket("/widget", scope: "/channels")`. Process options cannot relocate
compiled routes. Browser input, connector settings and endpoint-policy configuration
cannot supply this scope. The package validates scope/path conflicts and owns all
derived assets, installation, readiness and cookie paths; ZAQ does not copy assets.
Offline installation explicitly supplies the trusted mount scope. The package's
unscoped public API retains root deployment compatibility.

Key generation/rotation uses 32 cryptographically random bytes encoded as unpadded
base64url and the existing encrypted `channel_configs.token` field. The administrator
receives the new key once in the confidential operation response for secure host-backend
provisioning. Dismissal, selection, refresh or reconnect clears the reveal; ordinary
snapshots never reveal a stored key. Resolved `config.token` is available only to the
trusted server-side runtime builder. Sink hooks retain only the bound ID, not the key.
Rotation refreshes the runtime; failed synchronization is explicitly pending and must
be retried. The external adapter owns rejection of old-key assertions and revocation
of affected sessions; ZAQ cannot promise that an external session has been revoked.
