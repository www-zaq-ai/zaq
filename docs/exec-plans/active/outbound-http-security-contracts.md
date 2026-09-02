# Outbound HTTP Security Contracts

Beadwork: `zaq-w3s.1`

This document fixes the contracts for secure outbound HTTP requests used by agents and workflows. Implementation is tracked by dependent Beadwork issues under `zaq-w3s`.

## Goal

Agents and workflows may issue outbound HTTP requests only through a globally managed, BO-configured, channels-enforced security boundary. The default posture is fail-closed: the action is disabled until an admin enables it, private and special-use networks are blocked, URL userinfo is rejected, redirects are disabled, and only safe methods are allowed by default.

## Threat Model

The request source is untrusted LLM/workflow input. A prompt may try to:

- reach localhost, cluster service names, RFC1918 addresses, link-local metadata endpoints, IPv6 local ranges, or admin-blacklisted destinations;
- smuggle credentials through headers, query strings, URL userinfo, logs, traces, or action results;
- bypass validation by forging a `%Zaq.HttpRequest{}` or injecting `Req` options through event opts;
- use redirects, DNS rebinding, multiple DNS answers, or credential forwarding to reach a destination that was not validated;
- use mutating HTTP methods when the admin intended read-only access.

## Policy Contract

`Zaq.System` owns the global outbound HTTP policy. Policy settings are persisted through the existing system configuration path and exposed through public context functions. Runtime reads must go through `Zaq.Config` or the persisted system-config API so tests can use explicit config overrides.

The policy includes:

- master enablement;
- independent SSRF switches for loopback, RFC1918/private networks, link-local, cloud metadata, carrier-grade NAT, multicast, unspecified, reserved, IPv6 link-local, and IPv6 unique-local ranges;
- exact-host, domain-suffix, exact-IP, and CIDR blacklists;
- allowed HTTP methods;
- optional allowed ports;
- maximum receive timeout;
- maximum response size;
- redirect policy, initially disabled.

Invalid or missing policy data fails closed.

## Credential Provider Contract

Auth Credentials remain stored in `connect_credentials`. Credentials own encrypted secret material only. They do not own placement, header/query names, host restrictions, or agent/workflow availability.

Dynamic outbound HTTP providers are BO-managed rows referenced from `connect_credentials.provider` using the sentinel form:

```text
http:<provider_id>
```

A single provider-reference module must format and parse these values. It must reject malformed dynamic references and reserve the `http:` namespace so static provider names cannot collide.

Dynamic provider rows own:

- provider name;
- auth kind;
- placement strategy;
- header or query parameter name when required;
- enabled state;
- destination host patterns;
- non-secret metadata.

Provider host patterns only narrow global policy. They never allow a destination blocked by global policy.

## Request Contract

The action input may contain method, URL, non-secret headers, non-secret query parameters, body, body format, timeout, documentation reference, and optional `credential_id`.

It must never contain plaintext credentials, rendered authorization headers, URL userinfo, provider placement settings, provider IDs independent of credentials, or arbitrary `Req` options.

Validation is shared and phase-based:

- structural validation normalizes URL, method, headers, query, body, timeout, and credential reference;
- policy validation applies action enablement, methods, ports, blacklists, literal IP/CIDR checks, and timeout limits;
- channels edge validation asks Engine to prepare the request, resolves DNS on the channels node, checks every resolved address against Engine's policy snapshot, injects Engine-rendered credential material, and then opens the socket.

A `%Zaq.HttpRequest{}` value is not validation proof. Every public network execution path must invoke the edge validation sequence.

## Transport Contract

`Zaq.Channels.Api` is the public execution boundary. It accepts only untrusted request specs, calls Engine to load policy/credentials and prepare the execution contract, then invokes `Zaq.Channels.HttpClient` locally. `HttpClient` must construct protected `Req` options internally and must not allow production callers to override URL, method, headers, query, authentication, redirect policy, retry policy, adapter, transport, timeout limits, or security request steps through event opts.

Credentials are resolved on the Engine node and returned to Channels only as Engine-rendered execution material for the immediate transport call. Plaintext may not cross Agent or BO boundaries and may not appear in event opts, workflow state, action output, traces, telemetry metadata, logs, errors, inspected structs, or returned URLs.

Redirects remain disabled until each redirect target can repeat the full destination and credential-forwarding validation.

## BO Contract

The BO UI lives under `/bo/system-config` as an Outbound HTTP tab. It manages global policy and dynamic HTTP providers using existing BO layout, flash, tab, form, table, and modal patterns.

BO reads and writes must route through role APIs and `NodeRouter`; LiveViews orchestrate only and do not own policy or persistence rules.

The UI must expose every SSRF switch requested by the product, blacklist editors, allowed-method controls, transport limits, provider management, and warnings when admins weaken defaults.

## Test Contract

Tests are written before implementation in each dependent issue. Required coverage includes:

- property tests for IP classification, CIDR containment, host normalization, suffix matching, method normalization, port validation, and provider-reference round trips;
- policy tests for secure defaults, invalid settings, each SSRF switch, blacklists, methods, timeouts, and fail-closed behavior;
- provider and credential tests for sentinel parsing, reference validation, provider deletion restrictions, placement rendering, and secret hygiene;
- boundary tests proving forged structs, bare maps, event opts, redirects, local/private targets, DNS rebinding cases, and protected `Req` options cannot bypass enforcement;
- action tests for runtime policy validation and aligned input/output shape;
- BO LiveView and E2E tests for settings persistence, provider management, destination rejection, public-request success, and authenticated request execution without plaintext exposure.

All touched files must be formatted and validated with `mix q` before the parent issue can be closed.
