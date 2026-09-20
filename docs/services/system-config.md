# System Configuration

This document covers runtime requirements for Back Office system settings,
including AI model configuration and SMTP secret encryption.

## Global Runtime Keys

- `system.global.base_url`

`system.global.base_url` is the canonical project base URL configured from
Back Office (`/bo/system-config`, Global tab). Features that need to compose
public callback/redirect URLs (OAuth2, webhooks, and future integrations)
should read this key.

Data-source provider watches use this value through `Zaq.Channels.WebhookUrl`
to build `/channels/webhook/data_source/:provider` callback URLs. When the key
is unset, BO disables external provider watch setup and watch-channel renewal
returns `{:error, :missing_global_base_url}` instead of creating a provider
channel with an invalid callback URL. ZAQ does not enforce HTTPS here; provider
connectors are responsible for returning provider-specific URL validation errors.

## AI Model Configuration (LLM, Embedding, Image-to-Text)

AI model settings are configured in Back Office at `/bo/system-config` and
persisted in `system_configs`.

- LLM config is read via `Zaq.System.get_llm_config/0`
- Embedding config is read via `Zaq.System.get_embedding_config/0`
- Image-to-text config is read via `Zaq.System.get_image_to_text_config/0`

### LLM Keys

- `llm.credential_id`
- `llm.model`
- `llm.temperature`
- `llm.top_p`
- `llm.supports_logprobs`
- `llm.supports_json_mode`
- `llm.max_context_window`
- `llm.distance_threshold`

### Embedding Keys

- `embedding.credential_id`
- `embedding.model`
- `embedding.dimension`
- `embedding.chunk_min_tokens`
- `embedding.chunk_max_tokens`

### Image-to-Text Keys

- `image_to_text.credential_id`
- `image_to_text.model`

These keys are no longer configured through `LLM_*`, `EMBEDDING_*`, or
`IMAGE_TO_TEXT_*` environment variables.

Provider and endpoint fields are sourced from the `ai_provider_credentials` row
referenced by each `*.credential_id`. Runtime authentication is resolved from that
row's associated canonical Connect credential and org grant; the legacy AI `api_key`
column is not a runtime source.

### Connect-backed AI credentials

Every AI provider credential has one unique `connect_credential_id`. System owns the
AI-specific provider/endpoint record and maps administrator authentication writes to
`Connect.save_credential_configuration/4`; Connect owns authentication configuration,
encryption, the canonical org grant and mutation notifications. Creation, update and
deletion compose in one database transaction. BO OAuth starts reuse the associated
credential through `OAuthAttempts.start_global_configuration/3`, so callback completion
also writes the canonical org slot rather than a legacy resource-bound grant.

OAuth credentials select an administrator-controlled behavior by stable
`metadata["auth_profile"]` ID. The Auth Credentials and AI Credentials forms list the
secret-free entries returned by the static Engine registry; Standard OAuth2 is the
default, while existing OpenAI Codex credentials retain `openai_chatgpt_codex`. The
selection belongs to the Connect credential, so global and Person grants use the same
redirect, PKCE, authorization-parameter and token-normalization behavior. Submitted
module names are never accepted or converted to atoms.

Keyless endpoints require explicit `metadata["auth_kind"] == "none"`. Their Connect
credential is constrained to disabled personal policy, configuration binding and no
secret fields, has no grant, and resolves to empty authentication. A missing or blank
API key without that marker is invalid; it is never interpreted as no-auth.

The rollout first adds the nullable association and no-auth constraints, then runs the
secret-free bounded preflight. Backfill proceeds only when every legacy row is an
already-associated row, readable/nonblank API key, exactly one legacy OAuth org grant,
or explicit no-auth row. It creates disabled Connect definitions, copies API-key or
OAuth material into canonical org slots, associates each AI row, and finally makes the
association non-null. Legacy OAuth source rows and the encrypted AI key remain only for
guarded rollback; runtime and portal provisioning do not read them. Rollback refuses
after personal policy/grants exist and never deletes the retained OAuth source grant.

## People Access

People access settings are managed at `/bo/system-config?tab=people_access` and
stored as numeric strings under `people_access.*`. `Zaq.System.PeopleAccessConfig`
owns typed defaults (including a seven-day session lifetime) and strict positive
integer validation. System exposes one grouped read and an atomic group save via
Engine events. Missing keys use defaults without writes; corrupt values return an
explicit error. Engine PeopleAuth and issuance reservations consume this group on
each operation. Channels failed-identification protection uses a local typed cache
refreshed through the existing Engine config action at startup and 30 seconds after
each completed fetch; requests never read DB or fetch config. Snapshots expire after
120 seconds from fetch start; any refresh error invalidates them immediately.
Save becomes visible on the next completed refresh, without resetting counters.
OTP/session expiry is fixed at issuance; current attempt and rate limits apply on
subsequent calls. The legacy independent cooldown key is ignored and preserved:
V1 uses Hammer's remaining fixed-window time instead.
explicit error. Engine PeopleAuth and issuance reservations consume this group on
each operation. Channels failed-identification protection uses a local typed cache
refreshed through the existing Engine config action at startup and 30 seconds after
each completed fetch; requests never read DB or fetch config. Snapshots expire after
120 seconds from fetch start; any refresh error invalidates them immediately.
Save becomes visible on the next completed refresh, without resetting counters.
OTP/session expiry is fixed at issuance; current attempt and rate limits apply on
subsequent calls. The legacy independent cooldown key is ignored and preserved:
V1 uses Hammer's remaining fixed-window time instead.
See [People access configuration](people-access.md#people-access-configuration-current)
for all eight fields, units, and read/write contracts, including the versioned OTP
HMAC key derived from the existing endpoint `secret_key_base`. Authentication tables
store only digests, never plaintext codes or bearer tokens.

Public PR4 authentication uses confidential Engine events and the existing
notification delivery path. V1 intentionally retains the OTP notification body
in the ordinary notification log; this is separate from digest-only auth rows.
Phoenix filters `password`, `secret`, `token` and `code` HTTP/event parameters.
The installed LiveView mount logger does **not** filter its session dump. Logger's
compile-time purge targets only `Phoenix.LiveView.Logger.lv_mount_start/4` to
exclude that dump on every page sharing the cookie, including BO. Other HTTP and
LiveView event diagnostics remain enabled. When reusing cached dependencies after
changing this configuration, rebuild LiveView before building the app:

```sh
MIX_ENV=prod mix deps.compile phoenix_live_view --force
```

Use the corresponding `MIX_ENV=test` rebuild before the log regression test.
The shared signed session cookie is HttpOnly/Lax and Secure in production. Its
browser-session lifetime is unchanged: no explicit Max-Age/Expires is set.
People session expiry remains database-authoritative.

## Outbound HTTP

Outbound HTTP for agents/workflows is controlled from `/bo/system-config?tab=outbound_http`.

- Global policy is persisted under `outbound_http.*` system config keys and read through `Zaq.System.get_outbound_http_policy/0`.
- The default posture is fail-closed: disabled, redirects off, safe methods only, and private/special-use networks blocked.
- Dynamic HTTP credential providers live in `http_credential_providers` and define auth kind, placement, parameter name, enabled state, and destination host patterns.
- Auth Credentials store encrypted secret material in `connect_credentials`; HTTP credentials reference providers with `provider: "http:<provider_id>"`.
- Agents pass only `credential_id` to `http_request`; plaintext secrets are resolved and rendered by Engine, then consumed only by Channels for the immediate transport call.

## MCP Endpoint Runtime Configuration

MCP endpoint changes from Back Office (`/bo/system-config`) are applied through
an event-first boundary:

- BO emits `NodeRouter.dispatch/1` action `:mcp_endpoint_updated` (destination `:agent`)
- `Zaq.Agent.Api` receives the action and delegates to `Zaq.Agent.RuntimeSync`
- `RuntimeSync` applies the required runtime updates for impacted configured agents

This prevents BO LiveViews from calling runtime modules directly and keeps
single-node/multi-node behavior consistent.

## Agent Skills Resource Storage

Agent Skill resource defaults are configured from Back Office at `/bo/system-config`, Skills tab,
and persisted in `system_configs`.

- `system.agent_skills.resources.provider`
- `system.agent_skills.resources.config_id`
- `system.agent_skills.resources.scope_id`
- `system.agent_skills.resources.folder_id`
- `system.agent_skills.resources.folder_path`

These keys define where new skill resource uploads are written. The first successful upload pins
the effective provider/config/scope/folder and `resource_root` onto the skill row. Changing global
defaults later does not move existing resources or change already-pinned skills.

Uploads land in a flat `{skill-name}/` folder under the configured folder path. The UI-selected
resource classification (`reference`, `asset`, or `script`) is stored in `agent_skill_resources`
with the canonical data-source document id; it is not encoded as a path suffix.

Reads and writes go through `NodeRouter.dispatch/1` data-source actions. Runtime resource listing
uses the DB rows only. Content reads first call `get_document` to mint a fresh
`materialization_handle`, then immediately call `download_document`; handles are never persisted.

### Signal Adapter Pattern

The `:mcp_endpoint_updated` action acts as an adapter signal from configuration
changes to runtime operations:

- create/update/enable endpoint -> sync MCP assignment runtime state
- disable/delete endpoint -> unsync runtime state for impacted agents

### Hot Runtime Patch Strategy

For MCP assignment-only changes, runtime sync prefers hot patching existing
running agent servers (no full restart required).

For structural configured-agent runtime changes (model/credential/job/strategy/
tool/options/flags), normal fingerprint-based restart behavior still applies.

### Atom and Capacity Guards

MCP runtime endpoint ids are deterministic (`:"mcp_<id>"`) and managed by
`Zaq.Agent.MCP.Runtime` with safety guardrails:

- atom memory usage threshold: block new endpoint atom creation at `>= 85%`
- endpoint hard cap: maximum `2000` MCP endpoints

These checks exist to prevent atom-table exhaustion and uncontrolled runtime
growth in long-lived nodes.

## Secret Persistence Standard (Strict, Global)

### Connect configuration versus grant secrets

Connect credentials retain legacy configuration-owned API keys and JWT keys.
The explicit `secret_binding` enum defaults to `:configuration`; in that mode
JWT configuration still requires issuer, private key, key ID and a valid auth
profile. Opt-in `:grant` mode relaxes only the configuration private-key requirement,
allowing a JWT key to live on a credential-bound grant. Issuer, key ID, profile and
delegation-subject validation remain unchanged. This mode is independent of
`personal_credential_policy` and `user_level`; it does not enable runtime resolution.

Canonical grants require their own API key, OAuth access token or JWT private-key
material. Their changeset never copies secrets from configuration. OAuth client
settings remain configuration-owned. `Connect.change_credential_grant/3` encrypts
grant secrets using the existing strict `EncryptedString` path and reports encryption
failures as changeset errors. Atomic configuration management now uses
`Connect.save_credential_configuration/2..4` and the canonical mutation delegates.
Its global instruction keeps, completely replaces, or removes the org slot in the same
transaction. Removal is idempotent and succeeds only when the resulting policy is
`required`; optional/disabled saves without usable global material roll back completely.
Person self-management authenticates through the existing confidential People gateway,
then delegates to `Connect.PersonCredentials`.

The new mutation boundary never returns changesets or decrypted schemas. Results are
allowlisted IDs/status/policy and errors are fixed atoms; encryption failure is
`:encryption_failed`. Config omission retains secrets, explicit blank/nil/masked
values reject, and complete grant replacement clears omitted optional material.
Replacement and revocation force every cleared secret column to SQL NULL through
changesets, even when corrupt or unavailable-key ciphertext already loads as nil.
All supplied secrets are freshly encrypted, even client strings beginning `enc:`.
That prefix is not proof of trusted ciphertext. Schema inspection redacts secret
fields and metadata; legacy APIs still return their original schema/changeset shapes.

Grant mutations accept only auth-kind-specific secret fields plus expiry and the
selected OAuth behavior's allowlisted non-secret account metadata, with no client
metadata or ownership/auth-field overrides. Non-OAuth configuration metadata is
restricted to `auth_profile_id` and `subject`; canonical OAuth metadata admits the
existing authorize/token URLs, auth profile, PKCE flag and allowlisted authorize params
documented in `engine.md`. Arbitrary token payloads/nested metadata reject. OAuth client
settings remain credential-owned and are not Person-editable. Canonical OAuth setup
stages an encrypted immutable candidate in a transient attempt (`zaq-jrg.6`), then
atomically saves completed configuration plus global grant. No incomplete credential
row or setup-state framework weakens disabled/optional global completeness.

`PeopleCredentials` authenticates a bearer with `PeopleAuth`, requires `access_profile`
for reads and additionally `manage_credentials` for writes/OAuth, then delegates to
`Connect.PersonCredentials`. Neither a struct nor `ActorNormalizer` authenticates a
caller. Current literal active identity is reloaded for every call and rechecked after
locking configuration for writes. OAuth attempts store only the initiating session ID;
callback completion revalidates that session and current permissions.

Person read DTOs contain only credential ID/name/provider/auth kind/policy and own
lifecycle status/expiration. They omit **all metadata**, configuration secrets, OAuth
client settings, grant IDs and global availability. Write DTOs contain only credential
ID/status; validation and encryption errors are fixed atoms without submitted params.
Only grant-owned optional/required definitions can be configured. Disabled retained
own grants may still be revoked (erase secrets, retain revoked row) or removed (delete
slot, restore absence), idempotently and only for the authenticated active Person.
Legacy org/user grant and BO User semantics remain distinct from Person ownership.
Trusted administrative status reads use the same secret-free projection with an
explicit canonical owner. They are not Person APIs and must be authorized by any BO
transport that adopts them.

### Runtime resolution secret lifetime (`zaq-jrg.4`)

`Connect.resolve_credential/3` is a privileged runtime-only API, not a public Engine
action. It checks every claimed literal active Person before policy, including
disabled policy; malformed/stale/alias identities never become global authorization.
Nil/BO/system actors intentionally select org only within this trusted capability.
Person management still requires its authenticated adapter precondition.

The resolver selects one canonical owner slot before checking status, config, expiry
and decrypted material. Selected failures never fall back, including expired/revoked
or unreadable personal rows. Configuration API/private keys are not fallback sources;
its local config projection excludes all secret columns. Selected OAuth preparation
reuses the shared refresh path with an expected raw snapshot, never another token flow.

`ResolvedCredential` is ephemeral, Inspect-redacted and has no JSON encoder or Ecto
schema. It returns only grant API key, OAuth access token, or JWT private signing PEM
plus required signing identity/profile. OAuth client and refresh secrets never enter
the result. Only selected-grant account ID/name string metadata is allowed; no global
metadata leaks into personal results. Its expiry is the earliest local configuration
or selected-grant deadline, and resolution samples the clock only after acquiring its
selection locks. Errors contain a normalized credential ID and fixed reason. Failures
tied to an already-selected grant also carry its trusted `owner_type` (`"person"` or
`"org"`) so the Agent presentation boundary can choose recovery guidance without
guessing from an HTTP status. This internal provenance must not expose owner IDs or
global-grant availability and is removed from public metadata. Do not serialize,
persist, log extracted authentication, or return the resolved credential through public
events. See `engine.md` for exact auth shapes, expiry/error semantics and the final-read
linearization/later server invalidation limitation.

Global AI consumers call the System association boundary, which delegates to
`Connect.resolve_credential/3` with the org actor. `ProviderSpec`, model discovery,
LLM, embedding, image-to-text, ZAQ Router activation checks and portal account sync
therefore consume the same canonical result. Unrelated legacy resource grants and the
AI row's retained migration key are ignored.

### OAuth refresh secret lifetime (`zaq-jrg.7`)

Refresh reuses existing provider HTTP and the canonical mutation/event transaction.
Two secret-free grant columns hold a UUID claim and 120-second lease; failures retain
only that bounded cooldown. Raw stored ciphertext participates in the pre-HTTP and
pre-save configuration/grant fingerprint, so unreadable/replaced material cannot be
mistaken for unchanged nil values. Current literal active Person identity is checked
before external token use and persistence. Revoked grants never reactivate through
refresh; recoverable expired OAuth grants may return to active.

Successful refresh retains an omitted refresh token only from the checked current row,
rotates a supplied token and strictly encrypts provider strings, including `enc:`-prefixed
values. Loaded token strings are consumed literally, without a second decryption pass.
Canonical direct token-cache writes reject; they require the claimed refresh boundary.
Canonical token HTTP reuses Connect's generic transport. Missing token URLs are
resolved through secret-free Channels provider-profile metadata, not dependency token
helpers that may substitute environment credentials or drop PKCE. Catalog fallback
requires an explicit nonempty client secret; absence fails closed before exchange or
refresh even with ambient provider secrets set. Configured generic token URLs retain
public-client behavior and omit nil secrets. Refresh requires no callback redirect.
Legacy org/user provider token helpers retain their existing fallback contract.
Provider errors are fixed safe atoms and never trigger global fallback. Network calls
run outside transaction locks, and late results lose to replacement, revocation,
deletion, config changes or a recovered claim. See `engine.md` for resolver integration,
bounded retries and the accepted post-check Person deletion/remote rotation limitations.

### OAuth attempt secret lifetime (`zaq-jrg.6`)

`connect_oauth_attempts.pkce_verifier` and `candidate_config` use strict
`EncryptedString`/`SecretConfig` encryption before insertion and redact inspection.
The latter holds only trusted admin setup configuration as encrypted JSON; Person
attempts have none. OAuth client secrets remain configuration-owned. Signed browser
state contains only a random opaque attempt ID, never PKCE, identity, config or tokens.
The internal deterministic SHA-256 fingerprint covers stored administrative configuration
including secret ciphertext, not a timestamp revision, and is never a public result.

Attempts expire exclusively after 600 seconds. Atomic claim commits before network IO
and clears both encrypted columns even when unreadable ciphertext loads as nil. Claims
cannot be retried; cancellation, failure and replay require a fresh start. Unclaimed
expired secrets remain until bounded `.8` maintenance processes them; this is not immediate
TTL erasure. No authorization code is persisted. Final grant replacement and secret-free
`.3` jobs commit together, retaining previous material if exchange/finalization fails.

The existing callback and provider OAuth dispatches mark their NodeRouter hops
`confidential: true` to skip workflow-stream broadcasting. Callback HTML/messages contain
status only (numeric grant ID allowed for legacy success), target the callback's own
origin and use no-store/no-referrer headers. Phoenix filters code/state/token/secret
parameters from logs. Person OAuth starts only through authenticated, permission-checked
self-service operations; the bearer itself is never persisted in the attempt.

`SecretConfig.encrypt/2` accepts the established `config:` override via `Zaq.Config`
for per-call encryption configuration; existing `encrypt/1` behavior is retained.
Ciphertext decoding validates AES-GCM nonce/tag lengths before invoking crypto, so
malformed payloads load as unavailable rather than raising. Usability performs only
local checks, never provider network authentication.

Canonical ownership uses the existing `owner_type/owner_id`; its resource pair is
server-derived as `connect_credential` and the credential ID string. The trusted
Engine changeset checks a literal current active Person but does not authenticate
callers. There is no Person FK or trigger: concurrent deletion can leave orphan
encrypted secrets, and synchronous erasure is not guaranteed. IDs must not be reused.
`Connect.PersonLifecycle` (`zaq-jrg.8`) removes orphan secrets in bounded,
deterministic, idempotent batches, retaining inactive literal owners. Accounts deletion
and merge invoke transactional cleanup/owner-only transfer plus attempt cancellation;
no secret ciphertext is decrypted or rewritten. `.4` resolution and `.5` management
already reject stale/ineligible identities without global fallback or alias-based
reidentification. OAuth finalization also rechecks persisted attempt existence so
cancelled in-memory claims cannot write late. Scheduled maintenance erases expired
attempts (including encrypted global candidates with no credential), but retains
nonexpired claims so healthy in-flight callbacks can finish. Claiming already clears
encrypted verifier/candidate columns; identity cancellation still removes claims
immediately. See `engine.md` for bounds, keyset continuation,
the separate consumed `connect_maintenance` queue and counts-only domain telemetry.

All sensitive values (API keys, tokens, passwords) must follow one strict write path:

1. Validate form changeset
2. Encrypt sensitive values with `Zaq.Types.EncryptedString.encrypt/1`
3. Persist encrypted payload only
4. If encryption fails, return `{:error, %Ecto.Changeset{}}` with a field-level error

There is no fallback to plaintext persistence.

### Current sensitive fields

- `ai_provider_credentials.api_key` (legacy migration/rollback field; not runtime authority)
- `email.password`
- `channel_configs.token`

### Error contract

- Missing key: field error contains `missing SYSTEM_CONFIG_ENCRYPTION_KEY`
- Invalid key: field error contains `invalid SYSTEM_CONFIG_ENCRYPTION_KEY`
- Other encryption errors: field error contains `could not be encrypted`

All BO forms must surface these errors to the user in the related input form.

## SMTP Password Encryption

ZAQ encrypts SMTP passwords before persisting them in `system_configs`.

- Encrypted at rest: `email.password`
- Module: `Zaq.System.SecretConfig`
- Cipher: AES-256-GCM
- Strict mode: saving a non-empty SMTP password fails if encryption config is missing or invalid

## Required Configuration

Configure this in runtime config (production) or local secret config (development).
For local Docker runs started with `./zaq-local.sh`, ZAQ writes `SYSTEM_CONFIG_ENCRYPTION_KEY` to `.env` automatically.

```elixir
config :zaq, Zaq.System.SecretConfig,
  encryption_key: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY"),
  key_id: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY_ID", "v1")
```

## Key Format

`SYSTEM_CONFIG_ENCRYPTION_KEY` must represent exactly 32 bytes. Accepted formats:

1. Raw 32-byte string
2. Base64 value decoding to 32 bytes (recommended)
3. 64-character hex string (32 bytes)

Generate a recommended key:

```bash
openssl rand -base64 32
```

## Key ID

`SYSTEM_CONFIG_ENCRYPTION_KEY_ID` defaults to `v1`.

- Included in encrypted payload metadata
- Intended for key rotation workflows
- Changing key id without providing matching key makes old ciphertext undecryptable

## Failure Modes

- Missing key on save: BO save fails for any sensitive field and shows a form-level encryption error
- Invalid key format: BO save fails for any sensitive field and shows a form-level encryption error
- Invalid ciphertext/decryption failure: SMTP test/delivery fails until password is re-saved with valid key config

## New Secret Field Checklist

When adding a new key/token/password field:

1. Use strict encryption (`EncryptedString.encrypt/1`) in the write path.
2. Return `{:error, %Ecto.Changeset{}}` on encryption failures (no `raise`, no plaintext fallback).
3. Ensure the LiveView/form displays field errors.
4. Add unit tests for success + missing key + invalid key.
5. Add LiveView regression test proving clear UI error rendering.

## Operational Notes

- Keep encryption key in secret storage (Kubernetes Secret, Vault, cloud secret manager, etc.)
- Do not commit raw key values in repository files
- For local development, prefer env vars loaded via untracked local secret files
