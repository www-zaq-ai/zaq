# WebBridge protocol

This is the detailed owner for the implemented **version 1** BO/widget protocol.
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
wire envelopes; Delivery/Response support `protocol_version: 1` (the default).
Other explicit versions are rejected. Use the published constructors rather than
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

## Delivery, responses and lifecycle

Delivery fields are required `consumer` (`:bo` / `:widget`), required `topic`,
`events` (semantic-to-adapter-name map, default `%{}`), optional `protocol_version` (default 1) and
optional positive `channel_config_id` (required for widget scope). Event names are
nonblank strings or nonboolean/nonnil atoms. Unknown semantic keys are rejected.
Widget messages require mappings for typing, create, edit, step, complete, failed and
error before creating the chat. Command/acceptance responses are returned directly
and must also be encoded by the adapter; they do not depend on PubSub subscription.

Responses contain `protocol_version: 1`, required `request_id`, required semantic
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
| `:message_complete` / `:message_failed` | Public `body`, `error`, persisted assistant/user references, `created`; safe dispatch failure can use `code: :dispatch_error` | `:pipeline_result` |
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

One temporary RequestOwner subscribes to a private unpredictable cluster PubSub topic
before dispatch, on the ingress Channels node. Only a serializable Delivery snapshot
crosses Engine/Agent role hops, never its PID or dispatch function. Async returns a
creation/accepted receipt; live order is typing active → assistant create → optional
updates/steps → typing inactive → one terminal. Transport assistant IDs stay stable
across these updates; persisted assistant/user IDs are separate payload references.
Transcript and private execution-record IDs are not interchangeable with chat/message IDs.

Sync returns one terminal Response and publishes no duplicate terminal to the original
adapter destination. `:web_widget_sync_timeout_ms` defaults to 30,000 milliseconds;
`:web_widget_async_timeout_ms` bounds live-owner retention to 300,000 milliseconds.
Positive settings are bounded to 900,000 milliseconds, otherwise defaults apply.
Timeout is an unknown outcome, not cancellation or permission to retry. Accepted Engine
work may complete later. Owners stop on completion/failure/expiry; duplicate live terminal
fallbacks are suppressed. PubSub is best effort, not durable replay or exactly-once
execution. Reconnect/owner loss/timeout recovery uses authorized canonical history.
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
trusted `adapter` implementing the widget-specific
[`WidgetAdapter`](../../lib/zaq/channels/web/widget_adapter.ex) behaviour:
`build(config, hooks)` and `embed_script(widget_id, base_url)`. Return from `build/2`
`{:ok, {state_child_spec_or_nil, listener_specs}}` or `{:error, reason}`. Existing
BridgeSupervisor starts children, rolls back partial startup and follows automatically
restarted PIDs. Start is idempotent; unchanged enabled config preserves runtime, changes
restart, and disable/removal tears down using the configuration snapshot. BO needs no
widget runtime. Startup/construction errors are returned, not success receipts.

Hooks include shared Message/Command/Context/Delivery/Response modules,
`widget_id = config.id`, presentation settings and
`sink_mfa: {Zaq.Channels.Web.Runtime, :from_listener, [%{id: config.id}]}`. Invoke it with
`payload, [context: verified_context]`. It accepts shared structs and a matching
widget Context, then dispatches closed Channels `:web_ingress` through NodeRouter.
Event data cannot replace bound config or choose a builder module.

Persisted presentation/embedding settings are `display_name` (nonblank, ≤200 bytes)
and `allowed_domains` (≤100 exact HTTP(S) origins without
paths/wildcards/userinfo/query/fragment). `stylesheet_url` is init-only and is
rejected in persisted settings. Server-owned `key_rotated_at` records key generation.
Saving an older connector removes its obsolete persisted `stylesheet_url` while
preserving unrelated settings.
Absent settings are allowed; the adapter must enforce its policy, including an empty
origin allowlist. A separate `widget_id` setting is rejected. ZAQ installs no widget
HTTP endpoint, route macro or socket. Follow the [handoff](../guides/web-widget-integration.md)
for BO references, constructor examples, executable fixtures and real-package acceptance.

Engine persistence and Channels construction reuse the same pure
[`WidgetSettings.validate/1`](../../lib/zaq/connector_config/widget_settings.ex)
contract; neither role duplicates its validation or calls the other role's runtime.

### Connector authentication and cookie settings contract

**ZAQ host support implemented; external enforcement pending.** The ZAQ form,
settings projection and runtime configuration support this extension. Saving a
value does not establish that the installed external adapter applies it.
Adapter work is tracked in [web_widget #10](https://github.com/www-zaq-ai/web_widget/issues/10)
and [#12](https://github.com/www-zaq-ai/web_widget/issues/12); contract coordination
is tracked in Beadwork `zaq-yx7`, with host implementation in `zaq-kgw` and `zaq-m0a`.
These requirements extend the existing settings
and runtime boundaries; they do not introduce another configuration store.

Persist these string keys in `channel_configs.settings`. Use the same keys in the
confidential management request and allowlisted BO snapshot. The trusted adapter
reads them from `config.settings` on `build/2`; they are not duplicated into hooks.

| Key | Value contract | Default for a new connector |
| --- | --- | --- |
| `identity_issuer` | UTF-8 string, 1–255 bytes, no leading/trailing whitespace | `zaq_issuer` |
| `identity_audience` | UTF-8 string, 1–255 bytes, no leading/trailing whitespace | `zaq_audience` |
| `same_site` | Exactly `"None"`, `"Lax"` or `"Strict"` | `"None"` |

Issuer/audience are exact, case-sensitive JWT `iss`/`aud` expectations, not URLs
or secrets. The parent backend signs with the same effective values. Present blank,
nil, invalid or wrongly typed values reject; they must not silently choose a fallback.
Engine and Channels reuse the pure `WidgetSettings` contract. A partial save such as
enable/disable preserves omitted settings; new connectors persist the defaults.

For existing connectors with missing identity keys, resolution is per key:
explicit connector setting → existing trusted adapter integration option of the
same name → the new default. Validate the selected value. BO must expose the
effective values and their source; it must not display a default while the running
adapter uses a legacy application override. Saving an explicitly edited value makes
it connector-owned. If the legacy value cannot be resolved, mark it unresolved
rather than implicitly replacing it. Unrelated edits must not migrate it silently.

A missing legacy `same_site` preserves the serving endpoint's existing effective
policy until explicitly changed; it must not silently relax cookies to `"None"`.
Its effective policy and source likewise need to be reported, or marked unresolved.
Resolved identity options, effective cookie policy, verifier selection, PubSub and
endpoint selection remain server-owned. Browser input cannot override them.

`"None"` requires a Secure cookie over HTTPS. The adapter must enforce the requested
policy on widget-scoped session cookies and keep the session compatible with the
existing LiveView handshake. It must not relax ZAQ's BO session cookie or let widgets
with different policies overwrite each other's cookies. A cookie scoped only to
`/widget/:id` does not reach `/live`; copying attributes onto the shared BO cookie
does not establish isolation. Host-mounted and package-endpoint modes must document
and verify the same session contract. Do not remove CSRF protection merely because
JWT authentication exists, or add another browser socket as an implicit workaround.

Until this is supported, settings may be saved as desired configuration but must not
be presented as applied. Report `cookie_policy_unsupported` or
`cookie_policy_mismatch` through the readiness contract below. `SameSite=None` does
not guarantee operation when a browser blocks third-party cookies. Explicit HTTP
development exceptions require a separately documented policy, not a silent weakening
of the production `"None"` contract. Configuration changes reuse the existing runtime
refresh and session-generation invalidation path.

### Adapter readiness callback contract

**ZAQ callback invocation and validation implemented; external probing pending.** Tracked in
[web_widget #16](https://github.com/www-zaq-ai/web_widget/issues/16).
The optional `status(widget_id, opts)` runs on the same configured adapter that implements
`build/2` and `embed_script/2`. ZAQ declares it in `WidgetAdapter`, invokes it through
`Web.Runtime`, validates it with `Web.Readiness`, and projects it through WebBridge's
ingress callback. Host work is tracked in `zaq-p6e`. Older adapters may omit it: that means unknown
health, not an unavailable adapter or a healthy runtime.

- `widget_id` is the positive integer connector ID; never a browser-selected ID.
- `opts` is a keyword list containing `timeout_ms: 2_000`, the total check budget.
  The adapter resolves serving endpoint and PubSub from trusted server configuration;
  these values and arbitrary probe URLs cannot come from the browser or widget settings.
- The callback is read-only and returns a plain map, never a ZAQ struct. It does not
  consume a JWT, authenticate a synthetic visitor, create a conversation, change
  runtime ownership or require an existing connection.
- A successful response has the schematic shape below. All five checks are required;
  `reason` is a closed atom from the table below or nil.

```elixir
{:ok,
 %{
   protocol_version: 1,
   status: :ready,
   reason: nil,
   checks: %{
     runtime: %{status: :ready, reason: nil},
     transport: %{status: :ready, reason: nil},
     delivery: %{status: :ready, reason: nil},
     authentication: %{status: :ready, reason: nil},
     cookie_policy: %{status: :ready, reason: nil}
   },
   effective_settings: %{
     identity_issuer: %{value: "zaq_issuer", source: :connector},
     identity_audience: %{value: "zaq_audience", source: :connector},
     same_site: %{value: "None", source: :connector}
   }
 }}
```

Every check and overall `status` is exactly `:ready`, `:starting`, `:unavailable` or
`:unknown`. Ready checks have nil reasons; other checks require a reason below.
Overall precedence is unavailable → unknown → starting → ready. The overall reason
comes from the first check with that status in this order: runtime, transport,
delivery, authentication, cookie_policy. ZAQ verifies this aggregation rather than
trusting a contradictory overall result.

| Check | What ready establishes | Allowed non-ready reasons |
| --- | --- | --- |
| `runtime` | The exact widget is registered and its configuration process responds | `runtime_not_registered`, `runtime_unresponsive`, `runtime_starting` |
| `transport` | The serving HTTP listener and its LiveView WebSocket transport are accepting connections | `transport_not_listening`, `transport_starting`, `transport_unverifiable` |
| `delivery` | The configured response PubSub is available | `pubsub_unavailable` |
| `authentication` | The installed runtime has a configured verifier and effective issuer/audience matching the desired settings | `identity_not_configured`, `identity_settings_mismatch` |
| `cookie_policy` | The serving widget session applies the desired cookie policy without affecting BO sessions | `cookie_policy_unsupported`, `cookie_policy_mismatch`, `secure_cookie_required`, `https_required` |

Any check may also return `check_timeout` or `check_failed`; these do not imply ready.
Use starting only for `runtime_starting` and `transport_starting`; use unknown for
`transport_unverifiable`, `cookie_policy_unsupported`, `check_timeout` and
`check_failed`. The remaining reasons indicate unavailable. Unknown fields, missing
checks, invalid source/value pairs and a ready check with a non-nil reason invalidate
the response. An unresolved effective value cannot have a ready authentication or
cookie-policy check.
Effective-setting sources are exactly `:connector`, `:application`, `:endpoint` or
`:default`; `:endpoint` applies only to `same_site`. An unresolved effective setting
is `%{value: nil, source: :unresolved}`. The callback must report values used by the
installed runtime, not merely repeat the desired database configuration. No keys,
JWTs, verifier MFAs, cookies, private runtime maps or exception text may appear.

Callback-level failures return `{:error, reason}` where reason is exactly
`:invalid_request`, `:check_timeout` or `:check_failed`. ZAQ bounds the complete
invocation to 2,000 ms, handles exceptions/exits, validates the version and closed
shape, and projects absent callbacks, timeouts, failures and malformed replies to
unknown with a safe explanation. Do not pass unbounded or raw diagnostics to BO.

In host-mounted mode, check the host endpoint serving `/live`; in package mode,
check the package endpoint. A registered configuration process, loaded module or
living endpoint supervisor alone does not prove a listening WebSocket transport.
If a reliable local transport check is unavailable, return `:unknown` with
`transport_unverifiable`. This contract proves local readiness only, not public
proxy/TLS reachability, successful visitor authentication or endpoint security.

ZAQ projects ready → healthy, starting → checking, unavailable → unavailable and
unknown → unknown through the existing Channels `:channel_ingress_status` event;
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
Configuration changes use confidential `:sync_channel_runtime` with resolved
before/after configurations. A saved result can have pending runtime synchronization;
it is not a rollback or confirmation that the endpoint is secure.

`embed_script(widget_id, base_url)` returns `{:ok, String.t()}` or `{:error, reason}`.
Engine authorizes the selected ID and resolves the global base URL; a confidential
Channels `:widget_adapter_setup` event invokes the trusted configured builder.
ZAQ accepts nonempty UTF-8 markup of at most 32,768 bytes and displays it as escaped,
copyable text, never executable BO markup. No signing secret is supplied to this callback.

Key generation/rotation uses 32 cryptographically random bytes encoded as unpadded
base64url and the existing encrypted `channel_configs.token` field. The administrator
receives the new key once in the confidential operation response for secure host-backend
provisioning. Dismissal, selection, refresh or reconnect clears the reveal; ordinary
snapshots never reveal a stored key. Resolved `config.token` is available only to the
trusted server-side runtime builder. Sink hooks retain only the bound ID, not the key.
Rotation refreshes the runtime; failed synchronization is explicitly pending and must
be retried. The external adapter owns rejection of old-key assertions and revocation
of affected sessions; ZAQ cannot promise that an external session has been revoked.
