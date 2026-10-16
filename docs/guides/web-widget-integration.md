# Web widget integration handoff

This walkthrough targets shared web protocol version **2** on the `refactor/webbridge`
implementation for [ZAQ issue 830](https://github.com/www-zaq-ai/zaq/issues/830).
The protocol source is [`lib/zaq/channels/web/`](../../lib/zaq/channels/web/), not a
second widget schema. Pin the final reviewed ZAQ revision when installing the
adapter. [WebBridge protocol](../services/web-bridge.md#widget-runtime-construction) owns the
runtime, trust and delivery contract. BO's working consumer is
[`ChatLive`](../../lib/zaq_web/live/bo/communication/chat_live.ex).

## Install an adapter-owned runtime

### Included candidate package

ZAQ pins `www-zaq-ai/web_widget` to the verified-profile and recipient-recovery candidate
from [#30](https://github.com/www-zaq-ai/web_widget/pull/30), built on the supervised-host
contract introduced by [#24](https://github.com/www-zaq-ai/web_widget/pull/24).
[`mix.exs`](../../mix.exs) and
[`mix.lock`](../../mix.lock) own the exact revision. This is an integration candidate,
not an assertion that the changes have merged into `main`. After acceptance and merge, change the dependency
selector in `mix.exs` from `ref` to `branch: "main"`, run
`mix deps.update web_widget`, and validate the resulting lock revision again.

1. Run `mix deps.get` and compile/restart ZAQ. The package's bundled browser assets
   are served at `/web_widget/assets/`; no separate widget npm build, asset copy,
   package database migration, or standalone widget server is needed.
2. `Zaq.Channels.BridgeSupervisor` starts shared children inside its dynamic subtree
   before loading enabled connectors. CommunicationBridge routes provider runtime
   startup to registered bridges; WebBridge assembles the options and resolves
   its registered adapter. Widget registration contains only
   `bridge: Zaq.Channels.WebBridge, adapter: WebWidget.HostAdapter`.
   Options include `Zaq.PubSub` and authentication membership; connector-key
   verification and timing defaults belong to the package. The dependency's OTP
   application alone starts no widget services or listeners. ZAQ's
   upstream `WebWidget.HostAdapter` supplies infrastructure and `WebWidget.Connector` child specs using resolved
   server-only connector configuration and trusted hooks. The bridge DynamicSupervisor
   tracks its stable supervisor PID; the package owns recovery and session invalidation.
3. ZAQ mounts the package router outside its BO/browser session pipeline, on
    Channels nodes only, at `/channels/widget`; signed backend controls use `/channels/widget-api`.
    The endpoint's package socket mount serves `/channels/widget/:id/live`. BO's `/live` and
   `_zaq_key`/Lax session policy are unchanged. The widget uses its own signed,
    HttpOnly cookie at Path `/channels/widget/:id`, including its `/session` bootstrap and
   scoped LiveView transport.
4. Pass explicit `authentication: [replica_nodes: [...]]` process options for
   distributed deployment. Every node starting widget
   infrastructure must appear in the same list; BO/Engine-only nodes start no widget
   infrastructure and do not need membership. Configure distribution connectivity
   and keep a majority available. Unnamed/single-node development and tests default
   to the current node. Do not deploy separate single-node memberships for replicas
   of one installation. This store is RAM-only; total state loss invalidates old
   proofs. See the package's authentication operations guide for recovery details.
5. Configure the normal HTTPS reverse proxy as described below. Set System
   Configuration's global base URL to that browser-accessible
   HTTPS origin, configure exact allowed parent origins, save disabled, generate
   the authentication key, then enable the connector. All three settings must be
   explicit before runtime construction; follow the legacy upgrade instructions.

### Proxy-terminated HTTPS and local development

ZAQ normally serves private HTTP behind an HTTPS reverse proxy. **No additional
ZAQ TLS listener or widget certificate variables are required.** The existing
endpoint's HTTPS URL (`PHX_HOST` in production) must match the public widget origin.
Configure these deployment inputs:

| Child process option | Purpose |
| --- | --- |
| `scope: "/channels"` | Trusted mount scope, matching ZAQ's compiled router/socket macros; supplied by WebBridge |
| `proxy: [trusted_proxies: [ip_tuple, ...], public_origin: "https://..."]` | Optional upstream forwarding policy; omitted in ordinary ZAQ startup |
| `authentication: [replica_nodes: [node_atom, ...]]` | Intended authentication replica membership, including the local node |
| `session: [partitioned: boolean, secure: boolean]` | Package cookie technical policy; partitioning defaults to true and HTTPS forces Secure |

The adapter consumes typed initialization inputs when generating child specs,
not browser settings or an endpoint widget-policy section. The generic
Channels supervisor accepts `host_options` and provider-keyed `adapter_options`.
For example, trusted deployment composition may generate its Channels child with:

```elixir
{Zaq.Channels.Supervisor,
 adapter_options: %{
    web_widget: [
      scope: "/channels",
      authentication: [replica_nodes: [:"channels@node1", :"channels@node2", :"channels@node3"]]
   ]
 }}
```

This is a deployment-specific composition example: supply your actual fixed
membership, not connected-node discovery or request headers.
Default PubSub is supplied by WebBridge, not the static supervisor. The package validates and owns
the resulting process configuration; endpoint references remain normal Phoenix
listener/secret/URL references. No dedicated widget TLS listener is needed.

#### Ordinary application startup behind ingress

Ordinary ZAQ startup omits the adapter's `proxy:` block. Infrastructure owns TLS
termination, forwarding-header sanitization and backend isolation. The host Endpoint
applies its existing `force_ssl[:rewrite_on]` settings before adapter guards and socket
dispatch. Production already configures `rewrite_on: [:x_forwarded_proto]`; no widget
proxy environment variable, peer allowlist or application startup wiring is required.
Native HTTPS works without forwarding normalization.

Development does not enable `force_ssl` by default. For an intentional ngrok setup,
configure the existing Endpoint in `config/dev.exs` using your public tunnel authority:

```elixir
config :zaq, ZaqWeb.Endpoint,
  url: [scheme: "https", host: "your-tunnel.ngrok-free.app", port: 443],
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost", "127.0.0.1"]]]
```

Restart/recompile intentionally after changing compile-time SSL configuration.
Keep the backend loopback-only or on a restricted ingress network, and require the
ingress to replace client-supplied forwarding headers. Then use ordinary
`mix phx.server` startup. No service is restarted automatically during validation.
See [host deployment guidance](../operations/deployment.md#3-restrict-backend-access).

Set **System Config → Global → Base URL** to the public HTTPS origin for generated
installation markup. Widget settings continue to own embedding origins, issuer,
audience and SameSite. Neither that URL nor an embedding allowlist proves a request
used HTTPS or establishes network peer trust. Existing BO cookie and SSL redirect
policy is unchanged.

Technical process defaults do not replace connector identity policy:
`identity_issuer`, `identity_audience` and `same_site` must remain explicitly saved
canonical settings. Changing technical session policy invalidates old transport
cookies; legacy cookies without signed Secure/Partitioned flags bootstrap afresh
through the loader. No host-side cookie migration is needed.

The ingress must preserve the public Host and replace `X-Forwarded-Proto` with the
actual original scheme. Forward `/channels/widget`, `/channels/widget-api`,
`/channels/web_widget/assets/` and scoped WebSocket upgrades. Missing forwarded port
is not a widget requirement in host-managed mode. Untrusted clients must not be able
to bypass ingress and forge the headers the host is configured to consume.

#### Plain HTTP on localhost

For same-site local development, start ZAQ normally with the explicit host flag:

```sh
WIDGET_DEV_MODE=true mix phx.server
```

WebBridge translates this into the existing listener process default
`session: [partitioned: false]`. Only the exact value `true` enables it; unset,
`false` and other values retain normal defaults. Explicit trusted session options
take precedence, and other providers and BO sessions are unchanged. This is a
process startup setting: restart intentionally when changing it. Do not enable it
in production; HTTPS remains the production setup.

For example, with ZAQ at `http://localhost:4000` and your parent application at
`http://localhost:4100`:

1. Set **System Config → Global → Base URL** to `http://localhost:4000`.
2. Save the widget's **SameSite** as **Lax** (or **Strict**) and allow the parent
   origin `http://localhost:4100`.
3. Keep explicit issuer/audience and the embedding backend's signed-token flow.
   The flag does not bypass authentication, CSRF or allowed-origin checks.
4. Generate the installation snippet and load it from the parent application.
   Refresh existing iframe sessions after changing cookie policy.

Use `localhost` consistently for both applications rather than mixing it with
`127.0.0.1`. Ports may differ while the origins remain same-site. This does not
enable genuinely cross-site HTTP iframe cookies: those need `SameSite=None`,
Secure/Partitioned and HTTPS. The flag never silently changes the saved SameSite;
the new-widget default **None** still rejects HTTP sessions with `https_required`.
Without the flag, dev/test startup does not relax widget cookies. Explicit process
options remain available for custom evaluation fixtures.

Readiness v2 discovers the uniquely matching endpoint and its actual listener;
no duplicate readiness configuration is needed. **Ready** means the local feed is
installed and responding, not that ingress security has been certified. An HTTP-only
feed can be ready even when its page and session correctly return exact
`503 https_required` without widget cookies. A validated HTTPS redirect can also
prove the guarded feed responds. Neither requires widget proxy configuration or a
successful insecure session. Missing/stopped listeners, invalid settings, wrong
mounts, unrelated error responses and stale observations do not become Ready.

For guarded HTTP, the response records `verification.scope: :local`,
`external_https: :not_checked` and `session_handshake: :not_checked`.
Successful permitted HTTP/TLS sessions retain their stronger observed checks.
Independently evaluate the public HTTPS/WSS path; Ready is not a security audit.
Local readiness may stay green while the proxy is down. If discovery is ambiguous
or cannot find a stopped endpoint, it reports Unknown rather than inventing a target.
`SameSite=None` and partitioned cookies still require HTTPS and Secure in the browser.

The embedding application's authenticated backend must implement the token URL
used by the generated snippet (default `/api/widget-token`). ZAQ does not install
a public signing endpoint. Provision the connector key to that backend only; issue
a fresh JWT with the exact configured issuer/audience and **integer** connector ID.
Never put the key in browser code. Verify first question, renewal, reconnect/restoration, and
signed backend disconnect against that application's real authentication flow.

For restoration after a parent-page reload, save the ID reported by the
`zaq.widget.conversation` event, authenticate the new iframe with a fresh proof,
then call `zaq.widget.updateContext({conversation_id: savedId})`. Verify both
`event.source` and the exact widget `event.origin` before accepting parent events.
Reload alone does not implicitly select a previous durable conversation.

Once restored, the adapter receives a ZAQ-resolved private recipient delivery binding
and subscribes before accepting messages. The same Person/connector uses the same
destination across authenticated tabs and full reloads. The binding is server-only;
embedding applications must not supply a topic or Person ID. Recovery loads authorized
history and a public processing indication; subsequent full-body events can restore
an assistant message even when its original create event preceded the reload.

### Legacy connector upgrade

The pinned package no longer inherits issuer/audience from application options or
SameSite from the endpoint. Missing values fail runtime construction. Before
upgrading an enabled legacy connector, disable it and explicitly populate all three
settings through the existing BO form, preserving its previous **actual** identity
expectations and cookie policy. Generate/provision a key if it lacks one, then enable
and verify readiness. Blank legacy form fields preserve omission on unrelated saves;
they are not compatible runtime defaults. No bulk rewrite or silent policy migration
is performed by ZAQ. Refresh existing iframe pages and update installation snippets
when switching from the old shared `/live` transport.

### Other adapter implementations

Configure the widget provider in the host application's existing Channels map:

```elixir
web_widget: %{bridge: Zaq.Channels.WebBridge, adapter: MyWidget.Adapter}
```

Implement the adapter callbacks declared by [`WebBridge`](../../lib/zaq/channels/web_bridge.ex).
`MyWidget.Adapter.build_runtime_specs(config, hooks)` returns
`{:ok, {state_spec_or_nil, listener_specs}}` or `{:error, reason}`. ZAQ starts and
stops these children through its existing supervisor. The builder can use its
own endpoint/listener modules; it does not need a compile-time dependency back
to ZAQ. `hooks` supplies constructor modules and a config-bound sink MFA.
If a provider needs shared infrastructure, implement `infrastructure_child_specs/1`
returning `{:ok, specs}` on the adapter. No provider flag is required. BridgeSupervisor
starts that child before connectors and fails bootstrap if it cannot start; a subtree
restart repeats ordinary bootstrap. Disable/removal stops only the connector child.
The connector's persisted ID is the widget ID. Configure presentation/embedding
settings according to the [canonical runtime contract](../services/web-bridge.md#widget-runtime-construction).

The adapter supplies its routes, socket/session verification, embedding
protections and subscription authorization; the host mounts them as required by
that adapter. Do not reuse the BO session/socket. Bundle the adapter's own default styling;
an optional website-specific HTTP(S) stylesheet can be supplied during initialization.

For connector settings and the optional readiness extension supported by ZAQ,
follow the canonical [configuration keys](../services/web-bridge.md#connector-authentication-and-cookie-settings-contract)
and [adapter status callback](../services/web-bridge.md#adapter-readiness-callback-contract).
Adapter issues #10, #12 and #16 linked there own the corresponding external work;
existing installation support does not imply the installed adapter enforces these
settings or implements actual transport probing. BO displays Unknown until readiness
can be verified; desired settings and observed effective values remain distinct.

## Configure in ZAQ BO

1. Open Channels → Communication → Web Widget and add a named configuration.
2. Configure exact allowed origins. An empty allowlist permits no embedding.
3. Select an agent using the existing connector-scoped `IncomingMessageRouting`
   rule, or retain inherited routing / choose NONE.
4. Save disabled, then generate an authentication key. Copy the once-shown key and
   securely provision it to the host application's backend through your ZAQ administrator.
5. Configure the global base URL in System Configuration and install the adapter
   before enabling. The widget ID is the saved configuration ID.
6. Copy the installation script generated by the adapter. The BO does not execute it.

The adapter implements `installation(config_or_id, base_url, opts)` returning
`{:ok, html_string}` or `{:error, reason}`. ZAQ supplies only the saved ID and global
base URL; the adapter owns script URLs and attributes. The result must be nonempty
UTF-8 text of at most 32,768 bytes and must not contain secrets. For example:

```elixir
# Optional for a host-local adapter; external packages can implement the same API
# without declaring a compile-time dependency on ZAQ.
@behaviour Zaq.Channels.WebBridge

@impl true
def installation(%{id: widget_id}, base_url, []) do
  # Escape any values inserted into HTML attributes in your adapter implementation.
  {:ok, MyWidget.Installation.script_tag(widget_id, base_url)}
end
```

## Server-side sender authentication

The connector key is encrypted at rest. The trusted runtime builder receives it as
resolved `config.token` on the server only. Never serialize that configuration or
key into browser initialization, script tags, public events, logs or canonical history.
An administrator provisions the same key to the host backend; visitors never receive it.

Recommended flow (implemented and verified by the adapter/host app, not by WebBridge):

1. The host backend authenticates its user and signs a short-lived identity assertion
   binding widget/configuration ID, external sender ID, expiry and an unpredictable
   assertion ID. Use a fixed vetted signing format/algorithm and audience/issuer binding.
2. Browser initialization submits the assertion, not a shared signing secret.
3. The adapter verifies signature, widget/audience/issuer binding, expiry and replay
   protection before constructing trusted `sender_id`. Reject missing or invalid proof;
   a browser-selected sender is never authoritative.
4. Bind resulting sessions/subscriptions to that verified identity. ZAQ independently
   checks People identity, enabled connector, private conversation and canonical history.
   ZAQ itself rejects widget capabilities, including `:skip_permissions`, and revalidates
   Context at ingress; adapter filtering is not the sole protection.
5. On confirmed BO rotation, provision the replacement key to the host backend.
   Rebuilt adapter runtimes must reject old-key assertions and revoke affected sessions.
   Define and verify this policy in the external adapter; no silent old-key grace period.
   If ZAQ reports pending runtime synchronization, retry reconciliation before claiming
   revocation succeeded. ZAQ runtime status alone does not verify external session revocation.

## Instance stylesheet

Supply optional `params.stylesheet_url` during initialization as an absolute HTTPS
URL, or HTTP for development. ZAQ validates the URL but does not download/proxy it
or save it into the connector. The adapter loads it in the browser. Local paths,
`zaq://`, protocol-relative URLs and other schemes are unsupported; HTTPS pages may
block HTTP stylesheets as mixed content. Adapter-owned CSP and privacy policies must
account for the external stylesheet host. Omit the parameter to use default styling.

## Invoke the published sink

The following is schematic adapter code. It assumes `hooks` came from the trusted
runtime builder, `verified_sender` was obtained from server-side parent-app
identity verification, and `authorized_topic` was selected by the adapter for
that verified session. Neither value comes unchecked from browser payloads.

```elixir
delivery_module = hooks.delivery
context_module = hooks.context
command_module = hooks.command
message_module = hooks.message

{:ok, delivery} = delivery_module.new(%{
  consumer: :widget,
  channel_config_id: hooks.widget_id,
  topic: authorized_topic,
  events: %{
    typing: "response.typing",
    message_create: "response.message.create",
    message_edit: "response.message.edit",
    message_step: "response.message.step",
    message_complete: "response.message.complete",
    message_failed: "response.message.failed",
    error: "response.error"
  }
})

{:ok, context} = context_module.new(nil,
  consumer: :widget,
  channel_config_id: hooks.widget_id,
  sender_id: verified_sender,
  delivery: delivery
)

{module, function, args} = hooks.sink_mfa
invoke = fn payload -> apply(module, function, args ++ [payload, [context: context]]) end

{:ok, init} = command_module.new(%{
  request_id: "init-1",
  type: :conversation_init,
  params: %{stylesheet_url: "https://your-site.example/widget.css"}
})
readiness = invoke.(init)

{:ok, question} = message_module.new(%{
  request_id: "question-1",
  message_id: question_uuid,
  timestamp: DateTime.utc_now(),
  channel: "default",
  mode: :async,
  content: question_text,
  prompt_context: retained_parent_context
})
receipt = invoke.(question)
```

The adapter subscribes to its authorized pre-creation destination **before**
sending the question. Opening a widget creates no chat/history. Retain optional
parent context until the first actual question; do not send privileged prompt
inputs, fabricated People bearers or BO permission capabilities. Resume by
supplying the authorized `conversation_id`; it does not reseed context.
Validate any raw supplied resume ID before construction: shared optional identifier
normalization can yield nil for malformed values. Do not translate a malformed resume
request into a fresh-chat question; unknown valid IDs still fail closed in Engine.

Commands return a semantic Response directly. Async messages return
`{:ok, Response}` submission receipts without an assistant ID; synchronous messages
return one terminal Response or a no-answer submission acknowledgement. Widget responses
and Delivery use protocol version 2; BO remains version 1. A successful submission
does not promise an assistant answer and never exposes steering/execution internals.
Errors before acceptance can return `{:error, reason}`. Encode responses according
to their semantic type and retain request/conversation/message correlation.
PubSub events are `{:web_response, adapter_event_name, response}`. They are already
public projections; do not inject BO traces or raw tool calls into wire output.

## Lifecycle walkthrough

| Adapter action | Observable behavior |
| --- | --- |
| Open → init | Readiness, `created: false`, no new conversation ID |
| First async question | Creation receipt with new conversation ID |
| Submitted input without an answer | Receipt only; no assistant placeholder or pending-answer spinner |
| Started assistant message | Typing active → assistant create → optional edits/steps |
| Streaming edit | Replace the full content snapshot; never append it as a delta |
| Completion/failure | Typing inactive → one correlated live terminal |
| Sync question | One terminal or no-answer acknowledgement return; no duplicate terminal PubSub delivery |
| Sync timeout | Unknown outcome; no cancellation or automatic retry |
| Restore | Authorized shared history command with the existing conversation ID |
| Unknown/foreign/deleted resume | Denied; no replacement conversation |

The assistant's stable transport ID is not necessarily its persisted message ID.
Terminal payloads expose persisted assistant/user references separately. History
is the recovery interface after timeout or reconnect; PubSub offers
no durable replay or exactly-once execution promise. See the
[WebBridge protocol](../services/web-bridge.md) for bounds, pagination and timeout settings.

## Conformance and external acceptance

Executable host references:

- [`widget_conformance_test.exs`](../../test/zaq/channels/web/widget_conformance_test.exs):
  config-bound sink, real role dispatch, deterministic external LLM HTTP fixture,
  sync/async completion and authorized canonical history.
- [`adapter_contract_test.exs`](../../test/zaq/channels/web/adapter_contract_test.exs): dynamic adapter contracts,
  startup/failure, updates, teardown, isolated connectors and foreign context.
- [`adapter_status_test.exs`](../../test/zaq/channels/web/adapter_status_test.exs): existing
  Channels status event, safe projection, timeouts, effective settings and local scope.
- [`widget_delivery_test.exs`](../../test/zaq/channels/web/widget_delivery_test.exs):
  native-start ordering, no-answer acknowledgements, stable correlation and safe steps.
- [`sync_reply_test.exs`](../../test/zaq/channels/web/sync_reply_test.exs):
  bounded synchronous waits, no duplicate live terminal and timeout without cancellation.
- [`private_channel_boundary_test.exs`](../../test/zaq/engine/conversations/private_channel_boundary_test.exs):
  identity/privacy, lazy creation, context seeding, rollback, deletion and resume.

The external widget developer owns installation and endpoint acceptance:

- Mount the actual adapter package and provide its runtime builder/children.
- Verify parent identity/session and reject forged or unverified senders before
  constructing trusted Context. Treat `sender_id` as external identity, not a ZAQ Person ID.
- Verify signed identity assertion binding, expiry, replay handling and rejection after
  key rotation; keep keys strictly server-side and revoke affected external sessions.
- Enforce configured origins, iframe policy, session expiry and subscription ownership,
  including denial for an empty allowlist.
- Reject foreign widget/config/topic selection, unauthorized chat/history access,
  unknown wire events and all inbound message-edit requests.
- Exercise first question, seeded/unseeded history, resume without reseeding,
  streaming replacement, safe failure, timeout recovery, reconnect and endpoint restart.
- Confirm these checks with the real parent app and widget package, not only the ZAQ fixture.

Host fixture conformance does **not** establish actual adapter endpoint security.
Implementation progress and outstanding acceptance decisions belong in Beadwork,
not in this contract guide.
