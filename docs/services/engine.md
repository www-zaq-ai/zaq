# Engine Service

Foundation hardening evidence, acceptance map and measured coverage exceptions:
[`connect-foundation-validation.md`](connect-foundation-validation.md) (`zaq-jrg.9`).

## Overview

The Engine service is the operational backbone of ZAQ. Its responsibilities include:

1. **Conversations** — persisting and querying the full conversation/message/rating lifecycle.
2. **Notifications** — routing outbound notifications (email, etc.) through a centralized
   dispatch pipeline with audit logging.
3. **Channel Adapters** — supervising ingestion channel adapters (document sources) and
   retrieval channel adapters (messaging platforms).
4. **Routing and orchestration** — incoming message policy, workflows, event registration
   and durable data-source watch coordination.

The Engine runs under the `:engine` role. The top-level `Zaq.Engine.Supervisor` starts
`Zaq.Engine.Telemetry.Supervisor`, `Zaq.Engine.IngestionSupervisor`, and
`Zaq.Engine.RetrievalSupervisor`, workflow run registry/startup recovery and
`Zaq.Engine.EventRegistry` under a `:one_for_one` strategy.

Telemetry is a separate concern — see `docs/services/telemetry.md`.

**Important**: BO LiveViews must never call `Zaq.Engine.Conversations` directly.
New cross-service calls use `NodeRouter.dispatch/1` with `%Zaq.Event{}` and a
supported domain action. See the [dispatch contract](../architecture.md#noderouter--critical)
for request/actor preservation and the distinction from legacy generic invoke calls.

---

## Startup

The `:engine` role must be included in `:roles` config or the `ROLES` env var:

```elixir
# config/dev.exs
config :zaq, roles: [:bo, :agent, :ingestion, :storage, :channels, :engine]
```

```bash
ROLES=engine iex --sname engine@localhost --cookie zaq_dev -S mix
```

---

## Data Flow

### Conversations

```
Channel adapter or BO chat
  → Zaq.Engine.Conversations.persist_from_incoming/2
      → get_or_create_conversation_for_channel/3
      → add_message/2   (role: "user")
      → add_message/2   (role: "assistant")
          → Telemetry.record("qa.message.count" / "qa.answer.count")
          → TokenUsageAggregator Oban job (enqueued if model present)
          → TitleGenerator.generate/1 (async Task on first user message)
              → broadcasts {:title_updated, id, title} on "conversation:<id>"
```

### Notifications

```
Caller builds %Notification{} via Notification.build/1
  → Notifications.notify/1
      → filters recipient_channels against enabled ChannelConfig rows
      → NotificationLog.create_log/1         ← creates audit record
      → builds %Outgoing{} for each channel in order
      → Channels.Api handle_event(:deliver_outgoing) via NodeRouter.dispatch/1
          → on success: NotificationLog.transition_status("sent") and return final channel
          → on failure: tries next channel; "failed" if all exhausted
```

### Channel adapter lifecycle

```
IngestionSupervisor.init/1
  → ChannelAdapterLoader.children_for(:ingestion, @adapters, start_fun: :start_link)
      → ChannelConfig.list_enabled_by_kind(:ingestion, providers)
      → starts one child per enabled config

RetrievalSupervisor.init/1
  → ChannelAdapterLoader.children_for(:retrieval, @adapters, start_fun: :connect)
      → starts one child per enabled config

Adapter inbound path:
  External platform → adapter.handle_event/1
    → adapter maps to %Messages.Incoming{}
    → adapter.forward_to_engine/1
    → Agent Pipeline
    → %Messages.Outgoing{} via Outgoing.from_pipeline_result/2
    → Channels.Api handle_event(:deliver_outgoing) via NodeRouter.dispatch/1
```

---

## Modules

### Connect storage (`Zaq.Engine.Connect`)

#### Canonical credential-bound storage (`zaq-jrg.1`)

- `Credential.personal_credential_policy` is `:disabled` (default), `:optional`,
  or `:required`, with database NOT NULL and CHECK constraints. It is independent
  of legacy `user_level`; this storage slice does not enforce runtime policy.
- Canonical grants reuse `resource_type = "connect_credential"` and
  `resource_id = credential_id::text`, derived server-side with explicit non-null
  and equality CHECKs plus the existing credential FK. Native CHECKs validate
  resource types and owner shape. Legacy resource-bound org/user IDs are preserved.
- Person ownership uses only `owner_type = "person"` and non-null `owner_id`;
  canonical org ownership requires NULL `owner_id`. No duplicate identity columns,
  Person FK, conditional-reference triggers or guard rows exist. Credential deletion
  retains its existing cascade.
- Partial unique indexes reserve one canonical slot per credential/Person and
  one per credential/org (org has NULL owner ID), across active, expired and revoked
  statuses. Reconnection updates the retained row. Uniqueness is not provider-wide.
- `Grant.credential_changeset/3` derives credential ID, provider, auth kind, request
  format, scopes, JWT issuer/key ID/subject and resource pair from trusted configuration.
  The Engine entry point
  `Connect.change_credential_grant/3` also strictly encrypts changed secrets before
  persistence and checks the literal Person ID currently exists with active status
  on creation/update. It never follows merged aliases. These are internal storage
  changesets, not authenticated Person APIs. Atomic management uses the separate
  mutation boundary below. Authenticated self-service composes `PeopleAuth`,
  `PeoplePermissions` and the Connect management context at `PeopleAuthGateway`.
- Legacy issue/list/filter-based resolve stays resource-bound. Scheduled refresh includes
  canonical OAuth grants through the shared safe refresh boundary (`zaq-jrg.7`). AI
  provider credentials now associate to and resolve canonical rows through the System
  boundary; Data Source and MCP consumers remain legacy until their own integrations.
  No fallback from configuration secrets or legacy AI resource grants occurs at runtime.
  See [System configuration](system-config.md#connect-backed-ai-credentials) for the
  migration, explicit no-auth and rollback contract.
- Migration rollback locks the tables and refuses while canonical grants (including
  revoked/expired rows) or nondefault policy/secret-binding configuration exist.
  Operators must explicitly reconcile that data before rollback; it never silently
  drops Person identity or grant-owned secrets.

**Accepted lifetime limitation:** the current-record check does not coordinate
concurrent Person deletion/merge. Orphan grants and encrypted secrets can remain;
synchronous erasure is not guaranteed. Person IDs must not be reused operationally.
The authoritative approved storage decision is recorded in Beadwork epic `zaq-jrg`
and prerequisite `zaq-jrg.1` (2026-09-14).

#### Person lifetime and secret reconciliation (`zaq-jrg.8`)

`People.delete_person/1`, bulk deletion and the existing `PersonMerger` transaction
orchestrate `Connect.PersonLifecycle` before removing People. Accounts never queries
secret payloads. Single deletion still returns the deleted Person; bulk deletion
retains the deleted-count/failed-ID summary, including repeated historical aliases.
The whole bulk group acquires Connect locks once rather than per-Person lock passes.
The merger uses a protected People deletion operation after group-wide cleanup.

For each canonical credential, a survivor slot wins **in every status**, including
revoked and expired; losing rows and their encrypted material are deleted. With no
survivor slot, the lowest persisted loser ID's row transfers by changing only ownership
(and Ecto's update timestamp). Remaining losers are removed. Survivor-only rows are
untouched. No secret columns are loaded, decrypted, overwritten or re-encrypted.
Inactive survivors may retain transferred material; the resolver still rejects their use.
Existing canonical ownership CHECKs/unique indexes apply; legacy Person resource grants
remain prohibited. No new migration, Person FK, duplicate ownership column, trigger or
coordination row is introduced.

Lock order is Accounts' existing identity advisory lock, its Person/relationship locks,
then all discovered credential IDs ascending, grant IDs ascending, and OAuth attempt
IDs ascending. Canonical mutations/refresh/callbacks acquire credential locks first
and never acquire the Accounts advisory or Person locks. Merge and bulk deletion take
one group-wide Connect pass. Newly appearing credentials/rows outside that snapshot can
still leave the explicitly accepted concurrent orphan; no all-isolation erasure claim
is made. Person IDs **must never be reused** operationally.

All attempts for original participants, including the survivor, are deleted rather
than rebound to aliases. This includes claimed attempts currently exchanging with the
provider. Callback validation now requires the persisted attempt still exists under
the credential lock, both before HTTP and final save. A late callback or refresh cannot
overwrite transferred/deleted state. Remote provider operations already in flight
cannot be undone; a cancelled OAuth flow requires a fresh authorization attempt.

Grant identity is captured before mutation. Deletion emits `.3` `grant_deleted` jobs;
transfer emits old-owner `grant_deleted` and new-owner `grant_created` dependencies.
Collision also emits `grant_replaced` for the unchanged survivor slot to invalidate
that dependency later. Thus the survivor is notified even when it previously used
global fallback. Event kinds are dependency signals: consumers must re-read current
state. Every event has its own UUID and the existing eight-key secret-free allowlist.
Identity writes, grant changes, cancellation and jobs roll back together on failure.

`PersonLifecycle.reconcile/1` performs one deterministic ID-keyset page, default **100
grants plus 100 attempts**, with a hard per-kind limit of 500. Trusted callers may pass
`limit:`, `now:` and `after: %{grant_id: integer, attempt_id: string}`; the result contains
`grants_deleted`, `attempts_deleted` and an internal continuation cursor. Restarting
without a cursor is idempotent. It selects canonical Person grants whose **literal**
People row is missing, rechecks after locking, and deletes whole encrypted rows. It
does not follow aliases, remove inactive owners' retained grants, or touch legacy
org/user rows. Attempts are eligible when expired (`expires_at <= cutoff`) or
Person-owned with a missing literal owner. New global candidates with NULL
credential ID are included only when expired. Nonexpired claims stay until expiry;
claiming already clears encrypted material. Healthy in-flight exchanges survive
maintenance, while identity cancellation still removes claims immediately.

`SecretReconciliationWorker` runs every five minutes via the existing database-leader
`DynamicCron` plugin, with one outstanding unique worker job across pending/executing/
retry states, three attempts, and the dedicated **`connect_maintenance: 1`** consumed
queue on every dev/production role. It processes exactly one page, never recursively
enqueues continuation jobs, and the next scheduled run starts at the earliest remaining
eligible rows. Large backlogs drain over successive runs; this is not an immediate TTL
or bounded wall-clock erasure guarantee. Maintenance does not depend on `channels`
consumption or the deliberately unconsumed `connect_credential_notifications` queue.

Domain telemetry `[:zaq, :connect, :secret_reconciliation]` includes only deletion
counts, monotonic duration and a fixed outcome. Cursor/owner/config/grant IDs, raw
structs, metadata and secret values are excluded. Worker errors are fixed safe atoms.
Actual Agent invalidation/fanout, notification activation/replay policy and trusted
Person transport/session integration remain later delivery gates; `.9` validates the
combined foundation. Current `.4` resolver and `.5` management already reject stale
literal identities without alias normalization or global fallback.

#### Canonical mutations (`zaq-jrg.2`)

`Zaq.Engine.Connect.Mutations` owns the transaction boundary. `Connect` delegates:

- `save_credential_configuration(credential_or_id_or_nil, attrs, global \\ :keep, opts \\ [])`
  creates (`nil`) or reloads/updates configuration atomically with its global slot.
  `global` is `:keep`, `:remove`, or `{:replace, material}`. Removal is idempotent and
  valid only when the resulting policy is required. Disabled/optional policies require
  a locally usable canonical global grant; required permits absence or an unusable
  retained slot. Failure rolls back configuration, grant writes and notification jobs
  together.
- `replace_credential_grant(credential_or_id, owner, material, opts \\ [])` replaces
  the complete material, retains an existing slot ID and reactivates it. Optional
  material omitted from replacement is cleared, not inherited. Config fields omitted
  from save retain their values; explicit blank/nil/masked secret submissions reject.
  Non-null configuration fields `user_level` and `scopes` reject explicit nil before
  persistence; `false` and an empty scope list remain valid.
- `revoke_credential_grant(credential_or_id, owner)` clears secrets, cached expiry
  and metadata while retaining the revoked row. It does not require usable auth.
- `remove_credential_grant(credential_or_id, owner)` deletes the row, restoring
  absence semantics. Repeated cleanup of an absent slot succeeds.

Owners are explicit `:org` or `{:person, positive_integer_id}`. These are **trusted
internal APIs**, not browser-authenticated operations. Replacement checks the literal
current active Person without aliases. Cleanup permits missing/inactive People.
The accepted concurrent Person deletion/orphan risk above remains.

Every mutation reloads and locks the credential before locking the canonical owner
slot; the credential lock serializes absent slots too. Existing partial uniqueness
constraints remain the final defense. Policy-only changes preserve Person rows.
Changes to provider/auth kind/request format/scopes/JWT settings/OAuth client settings
or metadata reject while active canonical grants remain, except a global slot being
atomically replaced or removed. Revoke/remove incompatible Person grants first. Inactive rows
retain their original auth fields and are never reinterpreted under the new kind.
Legacy APIs retain their contracts and do not participate in this locking protocol.

Usability checks active status, derived configuration compatibility, required decrypted
material and local grant expiry (strictly later than `opts[:now]`, default UTC now).
API keys/access tokens must be nonblank; JWT material must decode as an RSA or EC
private PEM key with issuer/key ID. This does not verify provider acceptance. Corrupt
required ciphertext is unusable. OAuth accepts pre-obtained access material only;
  OAuth setup/finalization uses transient encrypted attempts (`zaq-jrg.6`, below),
  without incomplete credential rows or setup-state columns. Required-to-optional
  still fails until global material is supplied.

Replies are `{:ok, map}` with only credential ID, policy and optional global grant
summary for saves; grant summaries contain credential ID, grant ID and status.
Cleanup uses `"absent"` and a nil grant ID if already absent. Errors are fixed atoms
(`:invalid_configuration`, `:invalid_material`, `:invalid_instruction`, `:invalid_owner`,
`:person_unavailable`, `:not_found`, `:global_grant_unusable`,
`:incompatible_live_grants`, `:encryption_failed`, `:cleanup_failed`). No decrypted
schema, changeset or submitted params leave this boundary. Nested Repo transactions
compose: outer rollback undoes successful mutations; an inner failure aborts the outer
transaction. Secret-free notification jobs now commit with the writes (`zaq-jrg.3`).

#### Durable mutation notifications (`zaq-jrg.3`)

`Zaq.Engine.Connect.MutationEvents.persist/2` owns changeset persistence plus Oban
enqueue in the same `Zaq.Repo` transaction. `delete/1` reloads and locks the record
before capturing its identity and deleting it. Canonical and legacy credential
create/update/delete, grant issue/replace/revoke/remove, and shared token-cache/refresh
persistence use this boundary. Raw changeset construction alone is not a mutation API;
future OAuth and lifecycle writers must use this boundary rather than write directly.
Outer/nested rollback removes jobs too; enqueue failure aborts the mutation. Legacy
mutation errors retain their existing shapes, with an additional fixed
`:mutation_event_enqueue_failed` error. Canonical replies remain sanitized.

Version 1 jobs carry exactly these JSON keys:

| Key | Value |
| --- | --- |
| `version` | `1` |
| `event_id` | UUID, retained across delivery retries |
| `credential_id` | integer credential ID |
| `grant_id` | integer grant ID, or null for a configuration event |
| `owner_type` | `org`, `user`, `person`, or null for configuration |
| `owner_id` | integer owner ID or null (legacy nullable user/explicit org IDs retained) |
| `kind` | `credential_created`, `credential_updated`, `credential_deleted`, `grant_created`, `grant_replaced`, `grant_revoked`, `grant_deleted`, `grant_tokens_updated` |
| `occurred_at` | UTC ISO-8601 timestamp |

There is no artificial monotonic revision. No secret, provider payload, metadata,
raw schema, resource label or client-supplied event attribute is copied. Configuration
events cover every scope for that credential, including grants removed by cascading
credential deletion; those do not need individual grant events. Grant deletions retain
the persisted owner/grant IDs in the event. Empty changeset updates and absent-slot
cleanup enqueue nothing; replacements and forced secret erasure remain observable.
Delegated configuration saves emit one credential event and, when replaced, one grant
event, rather than duplicate credential notifications.

`MutationEventWorker` consumes queue **`connect_credential_notifications`** at concurrency
one, with three attempts and Oban's default jittered exponential backoff. Test
configuration remains manual because inline execution would dispatch before commit.

`MutationEvents.deliver/2` validates the complete payload, builds the existing synchronous
`:connect_credential_mutated` Agent event, and calls `NodeRouter.dispatch_all/1`. NodeRouter
discovers every currently connected Agent-role owner, applies a 30-second bound to each
remote RPC, and returns one acknowledgment per target. Zero targets, failed discovery,
lost acknowledgments, partial application failures, unexpected responses, exceptions,
exits, and throws all become fixed delivery errors so Oban retries the original job.
The Agent receiver validates again and synchronously calls its local `ServerManager`;
only acknowledgment after local admission fencing and stop/drain application is success.

Delivery remains at-least-once: duplicate and reordered notifications safely reapply
state-independent invalidation. The synchronous ServerManager mailbox orders delivered
invalidation against startup and dependency registration. Mutation-commit-to-processing
latency is accepted, and already-issued provider calls cannot be recalled.

Discarded jobs remain visible in `oban_jobs` with their safe fixed errors. Operators inspect
and replay them in a remote console using existing Oban APIs:

```elixir
import Ecto.Query

jobs =
  Zaq.Repo.all(
    from j in Oban.Job,
      where: j.queue == "connect_credential_notifications" and j.state == "discarded"
  )

Enum.each(jobs, &Oban.retry_job/1)
```

Confirm Agent-node discovery/connectivity before replay. Fanout covers discovered nodes
only; it does not guarantee delivery to an undiscovered or partitioned owner. There is no
bounded stale-authentication guarantee during those gaps or after exhausted retries.
Infrastructure issue #775 owns authoritative membership, partition admission policy, and
recovery before a node resumes service; it must use replay or service-specific state reset,
not heartbeat presence alone.

#### Privileged runtime credential resolution (`zaq-jrg.4`)

`Connect.resolve_credential(credential_or_id, trusted_actor, opts \\ [])` delegates
to `Connect.CredentialResolver`. IDs may be positive integers or numeric strings;
schema inputs supply only their ID and are always reloaded. This is a **trusted
runtime capability**, not a Person read API, public Engine action or authentication
adapter. No consumer is integrated by this slice. Generic internal invocation remains
trusted infrastructure and must not be exposed to browser input.

`ActorNormalizer.person_id/1` supplies canonical nested and legacy flat ID compatibility,
not authentication. Every supplied non-null nested/flat claim must be valid and agree.
Malformed actor values, conflicting claims, direct Person structs, and IDs with no
literal current active Person return `:person_unavailable` **before policy selection**,
even when disabled. Merge aliases never reidentify the owner. Nil, absent/null Person
fields and genuine BO/system actors select org intentionally in this privileged API;
they still do not authorize `PersonCredentials` management.

| Actor / policy | Selected slot |
| --- | --- |
| Active Person / disabled | Org; ignore all personal state |
| Active Person / optional | Personal row if present in any status; otherwise org |
| Active Person / required | Personal row; absence is `:personal_credential_required` regardless of org |
| Non-Person / any policy | Org; absence is `:global_credential_missing` |

Only exact canonical `connect_credential` resource/credential coordinates and exact
org/null or person/ID ownership participate. Selection happens before usability.
Revoked, expired, corrupt or incompatible selected rows are never treated as absent,
and **no selected failure triggers fallback**. Legacy resource grants and configuration
API/private keys are never material sources. Configuration-secret columns are excluded
from the resolver's configuration projection.

Success is `{:ok, %Connect.ResolvedCredential{}}`: credential/grant/owner IDs, string
auth kind/request format, the earliest local configuration/selected-grant expiry,
ephemeral `authentication`, and optional
selected-grant `account_id`/`account_name` metadata (strings, at most 255 bytes). No
configuration or other owner's metadata is copied. Inspection exposes only dependency
IDs/auth kind; no JSON encoder or Ecto schema is provided. Never log extracted auth,
persist this result, or put it into public events/DTOs.

| Auth kind | Exact generic `authentication` shape and semantics |
| --- | --- |
| `api_key` | `%{api_key: literal_string}`; nonblank, nonmasked decrypted grant key |
| `oauth2` | `%{access_token: literal_string}` only; no refresh token/client secret |
| `jwt_bearer` | `%{private_key: pem, issuer: string, key_id: string, subject: string_or_nil, scopes: list, auth_profile_id: string}`; RSA/EC private PEM; service-account profile, with subject required for delegated profile |

`request_format` is `"bearer"` (consumer applies Bearer formatting) or `"raw"`
(literal value). JWT returns signing material, not a minted assertion. There are no
ReqLLM options, Agent dependencies, provider authentication probes, or HTTP header
construction here. Loaded `enc:`-prefixed strings are consumed literally, never
decrypted twice. Provider acceptance and JWT signing belong to later consumers.

Errors are exactly `{:error, %{credential_id: normalized_id_or_nil, reason: atom}}`.
Reasons are `:person_unavailable`, `:personal_credential_required`,
`:global_credential_missing`, `:credential_revoked`, `:credential_expired`,
`:credential_unavailable`, `:credential_refresh_busy`, or `:credential_refresh_failed`.
They contain no submitted values, provider bodies, secrets or global availability in
personal failures. Revocation is terminal. Configuration/grant datetime expiry uses
strictly greater than `opts[:now]`; nil means no local deadline. Configuration expiry
is terminal; OAuth grant expiry/expired status may recover through shared refresh.
Wrong auth/config fields, invalid JWT material and unreadable required ciphertext are
unavailable. Missing refresh material on expired OAuth returns expired. Busy/provider
failure is safe and distinct; there are no in-call retries.

**Concurrency/linearization:** local work locks credential before selected grant and
checks literal identity again. OAuth uses `Connect.prepare_grant_for_use/2` once,
outside locks, with the existing raw ciphertext-inclusive refresh fingerprint as an
expected selection guard. Refresh checks it before cached use and again before claim.
After preparation the resolver reacquires locks, checks raw configuration, pinned slot,
current selection/identity and prepared material; unchanged cached material also checks
the raw grant/config fingerprint so unreadable nil values cannot hide replacement.
Configuration/grant expiry checks evaluate the clock after acquiring selection locks;
OAuth final validation evaluates it again after reacquiring locks. `now:` accepts a
fixed DateTime or a zero-argument clock; fixed timestamps stay
constant, whereas the default production clock and function overrides advance. Token
`expires_in` conversion uses the same clock seam after the provider responds.
Refresh's own claim fingerprint guards external work through persistence. Known stale
results reject rather than fallback. The final locked read/identity check is the
linearization point, not future consumer/server creation. Person deletion after that
check, later mutation and the server-create-versus-invalidation race remain outside
this resolver slice. `.8` supplies lifecycle cleanup above; `.9` is the remaining
comprehensive foundation review/validation gate.

#### Claimed OAuth refresh (`zaq-jrg.7`)

`Connect.refresh_grant(grant, opts \\ [])` reloads the persisted grant and configuration,
then coordinates canonical org/Person and legacy org/user resource grants through
`Connect.Refresh`. It reuses `OAuth.refresh_token_payload/3` and the existing Channels
provider fallback. Secret-bearing dispatch sets `confidential: true`. Generic provider
HTTP disables automatic retries, with 15-second receive and 5-second connect timeouts.
Provider errors, exceptions and malformed replies are sanitized before returning.
HTTP refresh failures retain the status and an allowlisted OAuth error code (for
example `refresh_token_reused`) for worker diagnostics. Raw provider bodies, messages,
parameters and unknown codes are discarded.
Canonical refresh always uses that existing generic token transport. When no
`token_url` is configured, Connect asks Channels for the existing provider profile's
token endpoint through `:data_source_oauth_token_endpoint`; only the URL crosses back.
It never delegates canonical token HTTP to a dependency helper with environment
credential defaults. Catalog fallback requires a nonempty bound client secret and
fails closed otherwise. An explicitly configured `token_url` retains generic
public-client support, omitting an absent secret. Refresh never needs a callback
redirect. Legacy org/user refresh retains its channel and ambient fallback behavior.

Migration `20260914120057_add_connect_grant_refresh_claim.exs` adds only
`refresh_claim` (UUID) and `refresh_claim_until` (UTC timestamp) to existing grants.
A short transaction locks configuration before grant and claims a **120-second lease**.
The claim commits before external IO; calling refresh inside an enclosing transaction
returns `:refresh_requires_committed_state`. A contender returns `:refresh_busy` without
HTTP or in-call retries. Failure retains the lease as bounded cooldown; process death
needs no cleanup worker to recover. The next caller can reclaim at the TTL boundary.
An old holder can remain in external IO after expiry, but cannot persist over a new
claim. Remote token rotation followed by process death can require reconnect if the
provider has invalidated the only stored refresh token; local leases cannot undo that.

Before HTTP and again before save, local transactions reload both records and compare
a deterministic fingerprint of **raw stored grant and configuration**, including
ciphertext, status, ownership, auth fields, policy and claim. No timestamp revision or
provider-wide locking is used. Revoke, removal, replacement, OAuth reauthorization and
configuration changes defeat the in-flight response. Person ownership checks the literal
current `status == "active"` record at both boundaries, without aliases. Missing or
inactive People never cause global fallback. Deletion after the final identity check
remains the accepted no-Person-FK/no-trigger race; lifecycle reconciliation is `.8`.

Canonical persistence uses the internal `Mutations.persist_refreshed_grant/4` writer
only after the claimed-refresh checks, with `MutationEvents` enqueue in that same
transaction. Tokens are freshly encrypted, omitted refresh tokens are retained from
the checked current row, and supplied tokens rotate. Provider scopes/metadata cannot
rewrite canonical configuration. The OAuth provider function consumes loaded plaintext
literally; an `enc:` prefix is never permission to decrypt a token a second time.
Legacy direct `update_grant_token_cache/2` reloads/checks status and grant material;
canonical use rejects with `:canonical_refresh_required`, preventing an unclaimed
cache writer from bypassing the refresh protocol. Enqueue failure rolls back tokens.

**Resolver `.4` integration:** after independently validating Person identity and
selecting policy/grant, call `Connect.prepare_grant_for_use(selected_oauth_grant, opts)`.
This internal API returns `{:ok, loaded_grant}` with runtime secrets, not a transport
DTO. It reloads identity/configuration and refreshes at or within the default 60-second
skew (`:refresh_window_seconds`). Future/no-expiry usable access tokens avoid HTTP.
Expired status or access-token expiry may recover with valid refresh material; revoked
is terminal. Missing refresh material returns `:authentication_required`. Other fixed
errors include `:not_found`, `:person_unavailable`, `:stale_grant`, `:refresh_failed`,
sanitized `{:oauth_refresh_failed, status}` tuples, `:invalid_refresh_response`,
`:encryption_failed`, and `:mutation_event_enqueue_failed`.
Busy/provider failures are retryable with bounded caller backoff, never a fallback
signal. `refresh_grant/2` is explicit refresh even for a future/no-expiry token.

The existing scheduler includes active/expired OAuth rows with stored refresh material
and expiry within its window. `GrantRefreshWorker.perform/2` carries runtime opts;
`perform/1` is the Oban entry point. Jobs retain a maximum of three attempts, with
120 seconds added to Oban's normal backoff so retries outlast the claim cooldown.
Both direct and scheduled refresh use the same lease. `:now` and `config:` are per-call
clock/runtime seams; no process-global config mutation is required. This slice does
not itself select policy, run `.8` cleanup, or activate consumers; the `.4` resolver
above now supplies canonical runtime selection.

#### Authenticated Person credential management

See [personal grant sequences](personal-grant-sequences.md) for module-by-module
creation, OAuth refresh, Person merge and Person removal flows, including transaction
and provider-network boundaries.

`Zaq.Engine.PeopleCredentials` composes the existing `PeopleAuth` bearer/session
boundary, `PeoplePermissions`, and the Connect-domain `PersonCredentials` operations.
Reads require `access_profile`; mutations and OAuth start/reconnect additionally
require `manage_credentials`. The latter is an explicit Everyone/team capability and
is not granted automatically. Submitted Person/owner IDs never select authority.

Credential requests use the fixed confidential `PeopleAuthGateway` operations. A
loaded Person struct remains a domain argument, **not authentication or an unforgeable
capability**. `ActorNormalizer` only normalizes runtime identity; actor maps, BO Users,
nil and machine flags cannot authorize management. The authenticated Person is
reloaded by literal ID and must currently exist and be active;
merge aliases are never followed. Every write rechecks after acquiring the credential
lock. The accepted post-check concurrent deletion/orphan limitation still applies.

| Function | Contract |
| --- | --- |
| `list_available(authenticated_person)` | Eligible grant-owned `:optional`/`:required` configurations, ordered by name/ID, with only the caller's own status. Legacy `user_level` does not affect eligibility. |
| `get_own_status(authenticated_person, credential_id)` | Eligible definition with own slot status, or a known retained own grant after disabling/changing binding. Unknown/ineligible-without-own-grant IDs return `:not_found`. |
| `put_own_authentication(authenticated_person, credential_id, material, opts \\ [])` | Complete API-key/JWT replacement through canonical mutations. Requires current grant binding and optional/required policy. OAuth material is not accepted here; use the one-use start/callback lifecycle below. |
| `revoke_own_grant(authenticated_person, credential_id)` | Clears own material, expiration and metadata; retains a revoked row. Absent slots stay absent. |
| `remove_own_grant(authenticated_person, credential_id)` | Deletes own slot and restores absence semantics. Repeated removal succeeds. |

Credential IDs are positive integers, not schema/grant references or ownership input.
Cleanup permits retained disabled configurations and is idempotent when the own slot
is already absent, even after policy/binding changes. It returns no configuration
details and never touches another Person, canonical org, or legacy org/user slot.
Missing configurations return `:not_found`; cleanup still requires an active Person.
Revocation retains an explicit denial slot for later optional-policy resolution;
removal permits later absence/fallback semantics. No resolver is implemented here.

Read success is `{:ok, summary}` or `{:ok, [summary]}`. Each summary has exactly
`credential_id`, `name`, `provider`, `auth_kind`, `personal_credential_policy`, `status`,
`expires_at`. Status is `"absent"`, `"active"`, `"expired"`, or `"revoked"`; an active
row whose expiration is not in the future reports expired. This is lifecycle status,
not provider verification, secret usability, or runtime resolution. Read queries select
only these fields and the caller's own slot; they do not load global grants or secrets.
No account metadata is approved in this slice, so **all metadata is omitted**.
`Connect.get_credential_grant_status(credential_or_id, owner, opts \\ [])` reuses the
same projection for a trusted explicit `:org` or `{:person, id}` administrative read.
It is not exposed through People dispatch and performs no caller authorization; future
BO integration must retain its NodeRouter and BO authorization boundaries.

Write success is exactly `{:ok, %{credential_id: id, status: status}}`; no grant IDs,
submitted values or secrets are returned. API-key material permits `api_key` and
`expires_at`; JWT permits `private_key` and `expires_at`. Canonical mutation validation
rejects unknown/duplicate keys and malformed values with `:invalid_material`.
Provider, scopes, issuer, key ID, subject, OAuth client settings, resource coordinates,
credential/grant/owner IDs and metadata cannot be supplied in material. Encryption
failure is `:encryption_failed`; canonical cleanup failures remain `:cleanup_failed`.
Errors are fixed atoms, never secret-bearing changesets or params. Trusted `opts`
carry the existing encryption-config/time seam, not client attributes. Nested rollback
undoes both slot writes and `.3` notification jobs.

Legacy `Connect.issue_grant/1` and `OAuth.build_authorize_url/2` explicitly reject
Person ownership (atom/string keys, including ambiguous maps) with
`:person_management_required`. The legacy callback rejects old signed Person-owned
state before exchanging any code. Existing generic Engine actions inherit these
checks through real context calls. Org/user behavior is preserved. Other generic
admin/runtime Connect CRUD, token-cache and resolver functions remain privileged
internal operations; none is exposed as a Person action. Person OAuth uses the
one-use trusted attempts below, never the legacy context path.

#### One-use OAuth and canonical admin setup (`zaq-jrg.6`)

The trusted backend API is:

- `PeopleAuthGateway.dispatch/2` operations `:start_self_credential_oauth` and
  `:reconnect_self_credential_oauth`, carrying the existing bearer and credential ID;
  these authenticate and authorize before preparing a session-bound attempt.
- `OAuthAttempts.start_global_configuration(credential_or_id_or_nil, attrs, opts \\ [])`
  is **explicit trusted admin setup**, not Person authority or browser attributes.
- `OAuthAttempts.finalize_callback(provider, params, opts \\ [])` accepts signed opaque
  state and an authorization code; callback identity comes entirely from the attempt.

Starts return only `{:ok, %{authorize_url: url}}`; finalization returns only
`{:ok, %{credential_id: id, status: "active"}}`. Fixed errors include `:unauthorized`,
`:not_found`, `:invalid_configuration`, `:incompatible_live_grants`, `:encryption_failed`,
`:oauth_failed`, `:invalid_attempt` and `:transaction_not_allowed`. Provider errors,
exception messages, token payloads and changesets never appear in these responses.
Self-service start/reconnect authenticate the bearer and persist the initiating
session ID, never its bearer or digest. Callback completion revalidates the session,
literal active Person and both required permissions before replacing authentication.
There is no sessionless Person start API. OAuth requires `auth_kind: "oauth2"`,
grant-owned secrets and optional/required policy. There is still no Person start route,
or UI in this foundation slice; the existing Engine gateway is the supported backend boundary.

**Admin setup decision:** the immutable candidate is encrypted only in the transient
attempt; no incomplete credential is created or modified. This is the smallest setup
path compatible with `.2`: after exchange, `Mutations.save_credential_configuration/4`
atomically creates/updates the complete candidate and replaces its canonical org grant.
Disabled/optional configurations always require a usable global grant at persistence;
required still permits ordinary configuration save without one. Admin setup validation
uses `Mutations.prepare_oauth_configuration/2`, an internal secret-bearing return used
only for encrypted staging, not a transport DTO. Config changes incompatible with live
Person grants reject before start and are checked again by canonical save at completion.
Failed setup leaves the existing credential/global grant unchanged, or creates neither.

Canonical OAuth configuration retains the existing credential fields and metadata
(`authorize_url`, `token_url`, `auth_profile`, `pkce`, and allowlisted `authorize_params`:
`prompt`, `access_type`, `include_granted_scopes`, `login_hint`, `audience`). Client ID,
client secret and scopes belong in their existing credential fields. `auth_profile`
selects a stable ID from `Zaq.Engine.Connect.OAuth.Registry`; missing selection resolves
to Standard OAuth2 and an unknown explicit ID is invalid. Registry entries are a static
allowlist with title/description metadata and implementation modules—never dynamic
module names from a request. This OAuth customization registry does not replace the
Channels provider catalog or introduce another OAuth application configuration.
Unknown/secret-bearing metadata rejects at the canonical admin boundary; Person inputs
cannot modify it.

Implementations of `Zaq.Engine.Connect.OAuth.Behaviour` may customize only redirect URI,
PKCE requirement, fixed authorization parameters and token-response normalization.
Connect still owns state, trusted owner/session checks, attempt binding, HTTP exchange
and refresh, encryption, grant writes and invalidation. Protected state, bound redirect
and generated PKCE parameters override provider additions. The Codex implementation
contains its loopback redirect, fixed ChatGPT authorization parameters, mandatory PKCE
and account-claim extraction; no Codex branch remains in the central OAuth module.
Normalized grant metadata is validated again against the selected implementation before
canonical replacement or refresh. Standard accepts none; Codex currently admits only a
nonblank `chatgpt_account_id`. Raw ID tokens and arbitrary provider payload fields are
never persisted as grant metadata.
Without explicit endpoint metadata, canonical authorization still uses the existing
provider catalog. Its `oauth_credentials: :explicit` event option passes through
Channels API into bridge context, making the bound client ID, redirect and scopes
(including empty) authoritative. Code exchange resolves the token endpoint through
the secret-free Channels profile lookup and reuses Connect's existing generic exchange
function. That function includes the exact server-bound PKCE verifier in the actual
HTTP form. Dependency exchange helpers are not trusted to retain it.

Catalog-based canonical exchange/refresh requires a nonempty bound client secret;
absence fails closed before token HTTP, even when provider environment secrets exist.
Configured generic `token_url` clients may omit a secret without consulting the
environment. Jido rejects direct explicit exchange/refresh delegation with
`:explicit_oauth_transport_required`. Public callback/refresh errors remain sanitized.
Legacy channel and ambient credential fallback is unchanged. No dependency patches,
provider-name lists, environment mutation or parallel token client were introduced.

Legacy `Connect.revoke_grant/1` rejects canonical schemas with
`:canonical_grant_requires_owner`. Trusted canonical callers use
`Connect.revoke_credential_grant/2` with explicit current ownership; Person callers use
`PersonCredentials.revoke_own_grant/2`. A stale pre-merge schema cannot revoke the
survivor's canonical grant or enqueue an event identifying the old owner.

`connect_oauth_attempts` binds a cryptographically random 256-bit ID to the credential
(nullable only for new admin setup), owner type/ID, provider, configuration fingerprint,
server redirect, expiry and claim time. Person ownership has no added Person FK or alias
resolution. The credential FK cascades deletion. The signed-but-readable browser state
has exactly one key, `attempt_id`. Every new attempt uses S256 PKCE; its verifier and
optional admin candidate JSON are strictly encrypted and redacted at rest. Codes are
never persisted. The SHA-256 fingerprint deterministically hashes the actual stored
configuration, including encrypted secret columns, excluding insertion/update timestamps.
It detects same-second edits and corrupt ciphertext changes; re-encryption conservatively
invalidates attempts. Fingerprints are internal and never exposed to the browser.

**Claim protocol:** expiry is exclusive at start + **600 seconds**. A short transaction
locks and irreversibly claims the unused attempt, clearing stored verifier/candidate
material, and **commits before network IO**. A second callback loses immediately. There
is no lease or claim retry: cancellation, provider mismatch, expiration, malformed
response, exchange failure, crash after claim or finalization failure require a new start.
After claim and again in the final transaction, the context verifies current configuration
fingerprint/provider, literal active Person, eligible policy/binding, server redirect and
deadline. Successful replacement uses the canonical credential-first lock and `.3` event
transaction, preserving slot uniqueness. Failed reconnect preserves the previous grant.
Browser/provider-returned owner, resource, config, scopes and metadata cannot override
binding; only access/refresh token and expiration are extracted from the provider result.
The accepted post-check concurrent Person deletion/orphan limitation remains.

`OAuth` reuses its existing authorize/exchange infrastructure. Generic authorization-code
exchange has automatic HTTP retries disabled: an ambiguous failure must restart. Public
attempt operations reject caller-owned Repo transactions to prevent network work under
an enclosing lock. Trusted `opts[:now]` accepts a DateTime or zero-argument clock and is
re-evaluated at finalization; `config:` uses the established `Zaq.Config` HTTP/encryption
seam. These options never come from callback parameters.

**Callback integration:** the existing `OAuth.finalize_callback/2` dispatches verified
attempt-shaped state to this context and preserves legacy org/user grant behavior.
`ChannelsController` uses its existing Engine invoke path, now marked `confidential: true`;
provider OAuth dispatches carry the same flag. NodeRouter routes these synchronously
without publishing code/state/client secrets to its workflow event stream. Callback HTML
contains only status (plus a numeric grant ID for legacy success), never raw errors or
reflected provider/params. Messages target `window.location.origin`, never `"*"`, with
`no-store` and `no-referrer` headers. Phoenix parameter logging filters code/state/secrets.
The new redirect is always `system.global.base_url` plus the existing provider callback
path (existing localhost default when unset); it cannot be supplied by the browser.
Legacy provider-specific redirects retain their existing behavior.

**Retention and lifecycle integration:** consumed attempts retain bindings/claim time
until `.8`'s bounded ID-keyset maintenance removes them. Expired attempts are deleted,
never reclaimed. Pending expired verifier/candidate material can remain until that
scheduled pass; no synchronous TTL erasure is promised. Callback validation rechecks
persisted existence, so lifecycle/maintenance cancellation also stops in-flight claims.
The exclusive deadline prevents late persistence. `.7` refresh compares current raw
grant/configuration after HTTP; `.4` validates literal Person eligibility before policy,
including disabled policy. `.8` cleanup/transfer and reconciliation are described above.
Distributed server invalidation remains a later consumer integration.

### Supervisor (`Zaq.Engine.Supervisor`)

- Top-level supervisor for the `:engine` role.
- `:one_for_one` children are defined in `lib/zaq/engine/supervisor.ex`; these include telemetry/adapters plus event registration and workflow recovery.

### Conversations Context (`Zaq.Engine.Conversations`)

- Public API for the full conversation/message/rating/share lifecycle.
- Access from BO crosses `NodeRouter.dispatch/1` and the Engine role API. Some existing callers still use generic invoke helpers; new calls follow the domain-action dispatch contract above.
- Dispatches `Zaq.Hooks` `:feedback_provided` event after a rating is saved.
- People self-service calls use the separate fixed confidential
  `PeopleConversations` facade, deriving literal ownership from fresh bearer
  authentication. It composes ordinary scoped context queries/persistence;
  authorization does not move into the persistence context. See
  [self-service conversation history](people-access.md#self-service-conversation-history).

**Key functions:**

- `create_conversation/1` — insert a new conversation.
- `get_conversation/1`, `get_conversation!/1` — fetch by UUID.
- `get_or_create_conversation_for_channel/3` — idempotent; returns the most recent
  active conversation for `{channel_user_id, channel_type, channel_config_id}` or creates one.
- `list_conversations/1` — filtered list; opts: `user_id`, `channel_user_id`, `channel_type`,
  `status`, `person_id`, `team_id`, `limit`, `offset`, plus `query` (case-insensitive search
  across titles and message content, SQL wildcards matched literally) and `from`/`to`
  (`DateTime` bounds on `updated_at`).
- `update_conversation/2`, `archive_conversation/1`, `delete_conversation/1` — lifecycle.
- `persist_from_incoming/2` — convenience: upserts conversation + stores both user and
  assistant messages from a pipeline result in one call. Accessed media bytes are
  stored in `message_trace_artifacts` in the same transaction as both messages;
  the assistant JSON trace receives only artifact IDs and safe descriptors.
- `get_authorized_trace_artifact/2` — returns artifact bytes only to the owning or
  shared BO user, with super-admin access across conversations. BO serves these
  through authenticated `GET /bo/trace-artifacts/:id`; unauthorized and missing
  artifacts are indistinguishable.
- `persist_message_history/2` — upserts/resolves a conversation from an Incoming routing
  envelope and stores one message, defaulting to assistant messages for initiated follow-ups.
  Email delivery providers such as `email:smtp` normalize to the existing `email:imap`
  conversation type; email grouping is resolved centrally from `metadata.email.thread_key`,
  `metadata.thread_key`, `metadata.topic`, `metadata.subject`, then thread/message ids.
- `add_message/2` — inserts a message, records telemetry, enqueues token aggregation,
  triggers async title generation on first user message.
- `list_messages/1` — all messages for a conversation in insertion order, preloads ratings.
- `rate_message/2`, `get_rating/2`, `update_rating/2`, `delete_rating/1` — per-message
  rating CRUD.
- `rate_message_by_id/2` — upserts a rating by message UUID; dispatches `:feedback_provided`
  hook after success.
- `rate_message_by_external_id/3` — resolves a message by its provider-assigned external id, then
  delegates to `rate_message_by_id/2`. Returns `{:error, :not_found}` when no message carries that
  id. Origin-agnostic: it takes the same `rater_attrs` map as `rate_message_by_id/2` and carries no
  channel or reaction vocabulary.

#### Rating a message from any origin

Ratings reach the engine through a single action, `:rate_message`, whose request is:

```elixir
%{
  message_ref: {:id, uuid} | {:external_id, provider_message_id},
  rater_attrs: %{optional(:user_id) => integer(), optional(:channel_user_id) => String.t(),
                 :rating => 1..5, optional(:comment) => String.t()}
}
```

`rater_attrs` is the same map the back-office builds (`MessageHelpers.positive_rater_attrs/1`) and
feeds straight into `MessageRating.changeset/2`. Only `message_ref` differs by origin: the BO holds
a message UUID, a channel only has the provider's identifier.

The engine cannot tell a reaction-originated rating from a back-office one — that is deliberate.
Channels map their provider's emoji vocabulary to a ZAQ rating _before_ dispatch (see
`Zaq.Channels.JidoChatBridge.ReactionMapper`) and dispatch through the shared
`CommunicationBridge.dispatch_message_rating/3` seam. A `:message_id` key inside `rater_attrs` is
rejected rather than ignored, since it would silently override the message resolved from
`message_ref`.

- `share_conversation/2`, `list_shares/1`, `revoke_share/1` — share link management.
- `get_conversation_by_token/1` — resolves a conversation from an unexpired share token.

### People Command Gateway (`Zaq.Engine.PeopleGateway`)

- The separate PeopleAuth lifecycle and Hammer ETS/PubSub limiter are documented in
  [People authentication backend](people-access.md#people-authentication-backend).
  Engine supervises OTP Person/IP issuance budgets and retains persisted verification
  attempts. Channels separately owns only unsuccessful-identification IP protection.
  Public callers use the fixed confidential `:people_auth` action and
  `PeopleAuthGateway`. Its single challenge request resolves a read-only match,
  issues and executes `NotifyPerson` through `Jido.Exec.run/3`, reusing the existing
  Notifications preferred/fallback delivery path through a confidential Engine event.
  Only `:sent` returns a safe challenge descriptor; failed sends invalidate only
  their own challenge. Verify/authenticate/revoke use bearer proof, never a
  client-supplied Person id. No LLM or workflow participates in delivery.
- Capability matrix/grant/revoke commands and their separate permission domain are
  documented in [People permissions](people-access.md).
- BO People operations dispatch to Engine using `action: :people_command`.
  Existing invoke-named event builders do not change that domain action's contract;
  new callers follow `NodeRouter.dispatch/1` with `%Zaq.Event{}`.
- `Zaq.Engine.Api` validates `%{op: atom(), params: map()}` and delegates to
  `Zaq.Engine.PeopleGateway.dispatch/2`.
- Gateway maps operations (`:filter`, `:create`, `:update`, `:delete`, `:bulk_delete`,
  team/channel operations, etc.) to `Zaq.Accounts.People` domain calls.
- Session administration uses fixed `:list_person_sessions`, `:revoke_person_session`,
  and `:revoke_all_person_sessions` operations. The gateway resolves the canonical
  Person from the positive `person_id` before calling `PeopleAuth`; BO receives only
  safe session metadata and active sessions are filtered with strict expiry semantics.
- `:resolve_selection` accepts `%{mode: :explicit | :all_matching, filters: map,
ids: [positive_integer]}`. IDs are inclusions in explicit mode, exclusions in
  all-matching mode. Filters are required; `%{}` explicitly means unfiltered.
  It reuses the listing's literal AND filters and stable `full_name, id` ordering,
  returning `{:ok, ids}` without pagination; malformed selections are rejected.
- People BO keeps compact filter-scoped selection across pages, resetting on filter
  changes. Opening bulk-delete confirmation resolves and freezes IDs server-side;
  confirmation consumes only that snapshot. Selection/filter changes or cancellation
  invalidate it. Later arrivals cannot join the deletion. `:bulk_delete` remains
  atomic (including cascades); invalid IDs reject the entire request and missing
  records roll back all deletes. The UI reports rollback as an error and clamps pages.

#### Canonical Person email

`Person` create/update changesets and `People.match_person/1` share
`Person.normalize_email/1`: trim, Unicode lowercase, and store blank email as `nil`.
Email is optional; omitting it on update preserves the stored value. Channel discovery
and backfill use the same canonical form. Duplicate creates/updates return an email
uniqueness changeset error rather than merging. Normalization does not validate syntax.

`PersonChannel` create/update changesets use `normalize_identifier/2` with the effective
platform, including platform-only updates. Only stored platform `email` uses the same
trim/Unicode-lowercase policy; its identifier is required. Other platform IDs retain
their case and whitespace. Ingress maps `email:imap` to `email`. People matching/linking
and identity channel selection normalize incoming identifiers and match stored values
exactly; runtime discovery does not scan or repair legacy variants. The global unique
index `channels_platform_channel_identifier_index` enforces one owner for each
`(platform, channel_identifier)` across all people. The same identifier on different
platforms is allowed. Both channel changesets attach conflicts to `channel_identifier`
with **This channel identifier is already assigned.**; BO renders its existing field
error without disclosing the owner.

Person create/update, partial discovery, linking and backfill are atomic. Email
channels are linked on creation or an actual email change; unrelated profile edits
and unchanged canonical emails do not repair missing channels or check their ownership.
Clearing email stores `nil` and preserves prior channel identities. Failed
email linking rolls back the Person edit and reports the error on the Person
form's `email` field. Failed channel discovery leaves no orphan Person or partial
backfill. Discovery links each distinct incoming channel/email identity once, including
the email used to create or backfill a profile. After a conflict on `people_email_index`
or `channels_platform_channel_identifier_index`, discovery retries once outside its
rolled-back transaction and rereads the committed winner. When called inside an
existing transaction it propagates the error instead of querying aborted SQL.
Contradictory email/phone and channel owners return a conflict, never reassign or
automatically merge. Unsupported channel platforms likewise fail atomically;
external permission import skips such unresolved principals without granting rights.

#### Person merges and historical identities

`People.merge_persons(survivor, single_or_list, opts \\ [])` accepts IDs or Person
structs and delegates atomic merge orchestration to `Zaq.Accounts.PersonMerger`.
The merger reconciles only supplied participants. The caller chooses the survivor;
email normalization migration alone discovers global components and chooses the lowest ID
in each connected identity component. Migration keys equate nonblank `Person.email`
with canonical email-channel identifiers; other channel keys use exact platform and
identifier. Transitive mixed-platform connections merge once. Blank Person emails
add no edges; blank legacy channel identifiers abort explicitly. Single-person
duplicate channels are cleaned separately, preserving the lowest channel ID/weight,
missing metadata and latest interaction in the migration's private singleton cleanup.
The migration also snapshots every source profile email and, after each component
merge, adds missing canonical email channels to the survivor. Losing profile emails
therefore remain discoverable even when no email-channel row existed originally.
This migration-only preservation keeps primary-email precedence and existing channel
metadata/activity; newly added identity channels have no recorded interaction.

- Survivor profile values win; missing fields and metadata leaves are filled from
  original records in ascending loser-ID order. Channel-seeded names count as missing.
  Teams are unioned and profile completeness recalculated.
- Channels are unioned by platform/canonical identifier, preferring the survivor's row,
  then original person/channel ID. Missing fields are filled and latest interaction
  wins; winner IDs and priority weights are preserved. Redundant rows are deleted before
  normalizing/reparenting the winner, within the merge transaction. Display history uses
  the original channel snapshot.
- Person rights are unioned per resource, independently of team rights. Grants on
  Person resources are reassigned and unioned per principal. Routing scopes are unioned,
  with survivor policy winning conflicts, otherwise lowest original person ID.
- Conversation ownership and typed notification recipient links move to the survivor;
  notification payloads remain unchanged. The merger uses ordinary owner APIs for
  channels, generic permission coordinates, routing, conversations and recipients;
  merge decisions belong to `PersonMerger`, validation/persistence to the owners.
- Authentication challenges and sessions are revoked for **every participant**, including
  the survivor, through ordinary PeopleAuth APIs in the same transaction. Credentials
  never transfer; loser auth rows cascade on deletion, survivor revocations persist.
  This remains available with corrupt auth configuration and rolls back with the merge.
  The authentication schema migration precedes historical email normalization so fresh
  replay can invoke the current merger without querying absent tables.
- Authentication challenges and sessions are revoked for **every participant**, including
  the survivor, through ordinary PeopleAuth APIs in the same transaction. Credentials
  never transfer; loser auth rows cascade on deletion, survivor revocations persist.
  This remains available with corrupt auth configuration and rolls back with the merge.
  The authentication schema migration precedes historical email normalization so fresh
  replay can invoke the current merger without querying absent tables.

The merger resolves and locks the complete supplied group in stable order, then loads
and locks its relationships. From these original snapshots it privately calculates
the complete profile, teams, aliases/history, channel reconciliation, permission unions,
routing winners and reference transfers before any write. Planned field values are
validated through owning changesets and APIs without no-op persistence. Database
constraints remain authoritative when applying mutations. Duplicate rows are deleted
before reassignment, references move before loser deletion, and all losers are deleted
before the final survivor email is written. `People.apply_merge_result/2` persists the
complete survivor, including protected aliases/history, in a single update through
`Person.merge_result_changeset/2`. This protected operation is not an ordinary resource
attribute API. The final Person and channels are reloaded inside the transaction and
returned only when it succeeds; nested callers retain control of their outer commit.

Merges serialize and reject self-merges, including aliases of the same identity.
Validation failures return controlled errors and roll back the whole merge, including
nested admin profile/channel edits. Team assignment/removal is transactional and
resolves and locks the current Person, preserving memberships across concurrent merges;
missing or forgotten identities return `:not_found`.

`People.update_person_resource/4` owns the outer transaction for combined requests:
merge persisted participants first, then apply ordinary profile/channel edits once to
the returned survivor. Explicit fields override merged values under both `"person"`
and `"other"` precedence; omitted fields retain the selected survivor's merge precedence.
Explicit `nil` values follow ordinary update semantics, including clearing optional
fields. Protected aliases/history cannot be cast from request attributes. Historical
labels always use original persisted snapshots. Existing channel edits must name the
same retained survivor channel ID, including transferred channels. A discarded ID
returns `:channel_not_found`, without retargeting. New channels use ordinary insert
uniqueness; collisions with retained channels or unrelated owners fail. Any edit failure
rolls back the entire request, including the preceding merge.

Losers are deleted. With default `retain_redirect: true`, their IDs and display history
are retained in the survivor's protected `merged_person_ids` and `merge_history` fields.
Ordinary create/update attributes cannot change these fields. Aliases are flattened
across successive merges. `retain_redirect: false` omits only new loser IDs/history;
inherited aliases/history from all merged people survive. Deleting the survivor also
deletes its aliases/history. Person IDs must not be manually recycled.

`People.get_person/1` is the alias-aware retrieval boundary. Build authorization
contexts from the returned survivor's ID and current teams. Downstream conversation,
routing, channel, permission and resource queries/writes use literal current IDs;
permission predicates do not reload supplied Person structs, and document query
predicates do not check Person existence. A failed retrieval must discard stale private
teams. `Ingestion.can_access_file?/2` retrieves the Person and uses current teams,
falling back to public access when missing. Explicit team-only query contexts keep
their contract; a nil Person is not an implicit permission grant and admin bypass is explicit.

BO detail shows **Merged entries** from the loaded Person's history: previous ID,
timestamp and original nonblank name, falling back to the primary channel identifier
(lowest weight, then ID), then `Person #<id>`. Inherited labels/timestamps are preserved.

Merges leave workflow definitions, run events/snapshots, cached inputs/results, approval
audit records and Oban arguments unchanged, including resumable runs. Historical names,
teams and approval attribution stay as recorded. Scheduled Person actions resolve IDs
through People lookup; notification and workflow recovery jobs use log and run IDs.
Unresolvable references follow the existing action's failure behavior.

For schema-first normalization, writer quiescence, backup and restore requirements, see
the [Person email normalization runbook](../operations/person-email-normalization.md).

### Conversation Title Generator (`Zaq.Engine.Conversations.TitleGenerator`)

- Generates a 6-word-max title from the first user message via LLM.
- Uses `Zaq.Agent.LLM.chat_config/1` and `Zaq.Agent.LLMRunner`.
- Called asynchronously (`Task.start/1`) — never blocks the message-storage path.
- Broadcasts `{:title_updated, id, title}` on `"conversation:<id>"` PubSub topic on success.
- `generate/2` — returns `{:ok, title} | {:error, reason}`.

### Token Usage Aggregator (`Zaq.Engine.Conversations.TokenUsageAggregator`)

- Oban worker; queue: `:conversations`, max 3 attempts.
- Triggered after each assistant message that has a non-nil `model`.
- Aggregates daily `prompt_tokens` + `completion_tokens` per model into
  `conversation.metadata["token_usage"][date][model]`.

### Messages — Incoming (`Zaq.Engine.Messages.Incoming`)

- Canonical struct for all inbound messages crossing the adapter boundary.
- Enforce keys: `:content`, `:channel_id`, `:provider`.
- Optional: `:author_id`, `:author_name`, `:thread_id`, `:message_id`, `:person`, `:attachments`, `:metadata`, `:routing_context`, `:is_dm`, `:content_filter`.
- All channel adapters must map their transport payload to this struct before passing to any
  ZAQ component.
- When crossing nodes, this payload is carried in `%Zaq.Event.request`.

### Incoming Message Routing

- `Zaq.Engine.IncomingMessageRoutingRule` is the single persistence model for incoming-message routing policy.
- Routing rule writes enter the Engine node through action `:upsert_incoming_message_routing_rules`. The Engine command normalizes rule maps and reuses `IncomingMessageRouting.upsert_rule/2` and `delete_rule/1` for all persistence and validation.
- `Zaq.Engine.Messages.Incoming.RoutingContext` carries transport-derived routing facts: `channel_config_id`, `retrieval_channel_id`, `topic_id`, and normalized attributes.
- Channels and BO Chat dispatch `%Incoming{}` to Engine with action `:route_incoming_message`.
- `Zaq.Engine.IncomingMessageRouter` resolves Person identity, honors any explicit event `agent_selection`, resolves the most specific valid routing rule, and returns an executable `%Zaq.Event{}` for `NodeRouter` continuation.
- BO Chat's agent selector is transient event state (`event.assigns["agent_selection"]`, `source: "bo_explicit"`), not a persisted routing rule.
- Email mailbox routing is represented by topic-scoped rules using `channel_config_id + topic_id`.
- Legacy global settings, provider settings, retrieval-channel fields, and IMAP `agent_routing` settings are not routing sources of truth.

Routing precedence:

1. Explicit event `agent_selection` (for example BO Chat selector)
2. Person + retrieval-channel rule
3. Person + topic rule
4. Person + provider rule
5. Person global rule
6. Retrieval-channel rule
7. Topic rule
8. Provider rule
9. Global rule
10. Default ZAQ agent

Agent-targeting rules and explicit selections must resolve to agents that are active and conversation-enabled; invalid configured-agent references are skipped during resolution.

Rule write commands accept a required `rules` list. Each rule carries optional scope keys (`person_id`, `channel_config_id`, `retrieval_channel_id`, `topic_id`), `routing_mode: "agent" | "none" | "clear"`, and `configured_agent_id` for agent mode. Example: `%{rules: [%{channel_config_id: 12, topic_id: "INBOX", routing_mode: "agent", configured_agent_id: 34}]}`. Single-rule updates submit a one-item list; IMAP mailbox saves use the same batch form so selected mailbox rules are updated through one standardized action call.

### Messages — Outgoing (`Zaq.Engine.Messages.Outgoing`)

- Canonical struct for all outbound messages.
- Enforce keys: `:body`, `:channel_id`, `:provider`.
- `from_pipeline_result/2` — builds an `%Outgoing{}` from an `%Incoming{}` and a pipeline
  result map; copies routing fields and stores result map in `metadata`.
- When crossing nodes, this payload is typically returned in `%Zaq.Event.response`.

### Notifications Context (`Zaq.Engine.Notifications`)

- Single exit point for all outbound communication from ZAQ.
- `notify/1` — accepts only a validated `%Notification{}` struct.
  - Filters `recipient_channels` against enabled `ChannelConfig` rows.
  - Creates a `NotificationLog` record, then delivers inline through Channels.
  - Returns a structured sent/skipped/failed result with final channel details on success.
- `bridge_available?/1` — returns true if a bridge is configured for the given platform.

`NotifyPerson` forwards the receipt's `message_id`, `thread_id`, and opaque
`thread_metadata` through Jido output validation. Metadata must be a map (omission
defaults to `%{}`; explicit `nil` is invalid), with arbitrary keys and nested values
preserved verbatim. Its NimbleOptions field uses `{:map, :any, :any}` because plain
`:map` restricts keys to atoms; Engine and the action do not normalize provider keys.

### Notification Struct (`Zaq.Engine.Notifications.Notification`)

- Build via `Notification.build/1` — validates subject, body, channel format.
- Fields: `recipient_channels`, `sender`, `subject`, `body`, `html_body`,
  `recipient_name`, `recipient_ref`, `metadata`.
- `recipient_ref` type: `{:user, integer()} | {:person, integer()} | nil`.

### Notification Log (`Zaq.Engine.Notifications.NotificationLog`)

- Ecto schema (`notification_logs`); stores payload (subject/body) and delivery audit trail.
- Status lifecycle: `pending → sent | skipped | failed`.
- `create_log/1` — inserts with status `"pending"`.
- `append_attempt/4` — atomic Postgres JSONB `||` append to `channels_tried`.
- `transition_status/2` — enforces valid transitions; uses `update_all` with current-status
  guard for stale-record safety.
- `record_threading/3` / `thread_anchor/2` — persist and resolve the **opaque** threading
  anchor of a **delivered** message. The anchor is the map the delivering bridge returned
  in its receipt, stored and returned verbatim; only the provider bridge interprets its
  keys (for email: `"message_id"`, `"in_reply_to"`, `"references"`, `"thread_id"`).

#### Outbound threading — anchor source of truth (invariant)

The notification center never interprets channel wire formats. Per delivery attempt,
`Notifications.resolve_anchor/2` fetches the prior anchor and passes it down on
`Outgoing.thread_anchor`; the provider bridge (e.g. `Zaq.Channels.EmailBridge`) mints
ids, builds headers, and returns a delivery receipt whose `anchor` the engine persists
on the `sent` transition. Resolution consults two stores in a fixed order:

1. **Primary — `NotificationLog.thread_anchor/2`.** The log is authoritative for the
   outbound chain: it is written by the code that saw delivery succeed, keyed by
   `(recipient_ref, thread_key)`, and only on the `sent` transition (never
   `skipped`/`failed`, so an undelivered message can't become a phantom parent).
2. **Fallback — `Conversations.latest_thread_anchor/4`.** The conversation store
   carries the anchor for a thread ZAQ did **not** start (an inbound email whose RFC
   id we inherited) and for messages persisted before the log path existed.
   `Conversations` has **zero channel knowledge**: the anchor is written at persist
   time by the delivering channel under `metadata["threading"]["anchor"]` and read
   back verbatim (presence is the only filter — the writing channel guarantees the
   anchor is usable). The grouping key and channel type are computed on the
   channels node: inbound envelopes arrive pre-stamped
   (`Incoming.metadata["conversation"]`, written by
   `Zaq.Channels.CommunicationBridge.put_conversation_identity/2`), and the
   Notifications fallback asks the channels node via the `:conversation_identity`
   event — engine modules never call bridge functions directly. Platforms whose
   bridge defines no grouping resolve a `nil` key and skip the lookup.

Both stores hand back the same string-keyed opaque map. Keep the two paths consistent
when editing either — a divergence would re-key a thread or drop the `References` head
(the thread root). Grouping stays `topic || subject` (via
`CommunicationBridge.outbound_conversation_key/4` on the channels node); it is
deliberately not re-keyed to the minted `Message-ID`. Email minting mechanics (Message-ID, References capping, sending domain)
live in the email bridge — see `docs/services/channels.md`. The generic anchor is
the single stored copy (no email-shaped duplicate, no backfill — the feature
shipped with write-time anchors from the start); rows without an anchor simply
don't resolve, starting a fresh chain.

### Welcome Email (`Zaq.Engine.Notifications.WelcomeEmail`)

- `deliver/1` — builds and dispatches a welcome email to a newly created user via
  `Notifications.notify/1`. Skips if the user has no email address.

### Password Reset Email (`Zaq.Engine.Notifications.PasswordResetEmail`)

- `deliver/2` — builds and dispatches a password reset email with a one-time token URL.
  Skips if the user has no email address.

### Ingestion Channel Behaviour (`Zaq.Engine.IngestionChannel`)

- Behaviour contract for document-source adapters.
- Required callbacks: `connect/1`, `disconnect/1`, `list_documents/1`, `fetch_document/2`.
- Optional callbacks: `schedule_sync/1` (polling), `handle_event/2` (event-driven).

### Retrieval Channel Behaviour (`Zaq.Engine.RetrievalChannel`)

- Behaviour contract for messaging platform adapters.
- Required callbacks: `connect/1`, `disconnect/1`, `send_message/3`, `send_question/2`,
  `handle_event/1`, `forward_to_engine/1`.

### Notification Channel Behaviour (`Zaq.Engine.NotificationChannel`)

- Behaviour contract for notification delivery adapters.
- Required callbacks: `available?/1`, `send_notification/2`.

### Data Sources Runtime (`Zaq.Engine.DataSources`)

- Owns durable provider watch-channel runtime state for external data-source webhooks.
- Persists `Zaq.Engine.DataSources.WatchChannel` rows with provider channel ids, resource ids, checkpoints, expiration, operational status, and provider metadata.
- Resolves webhook deliveries by provider `channel_id`/`resource_id`, or resolves provider setup/teardown by config and target source.
- Dispatches metadata-only provider deltas to Ingestion through `NodeRouter.dispatch/1`; checkpoint advancement happens only after Ingestion succeeds.
- Stores provider runtime status (`active`, `error`, `stopped`) separately from user-facing document watch status in Ingestion.

### Watch Channel Renewal (`Zaq.Engine.DataSources.WatchChannelRenewalWorker`)

- Oban worker on the `:channels` queue.
- Scheduled when an active watch channel has `expiration_at`; default lead time is one hour before provider expiration.
- Recomputes public webhook URL from `system.global.base_url` during renewal so URL changes are picked up.
- Creates a replacement provider channel before stopping and deleting the old row.

### Ingestion Supervisor (`Zaq.Engine.IngestionSupervisor`)

- Starts one child process per enabled ingestion `ChannelConfig`.
- Registered adapters: `"google_drive"` → `Zaq.Channels.Ingestion.GoogleDrive`,
  `"sharepoint"` → `Zaq.Channels.Ingestion.SharePoint`.
- Adapters started via `start_link/1`; `:permanent` restart strategy.
- Starts empty without crashing when no configs are found.

### Retrieval Supervisor (`Zaq.Engine.RetrievalSupervisor`)

- Starts one child process per enabled retrieval `ChannelConfig`.
- Registered adapters: `"slack"` → `Zaq.Channels.Retrieval.Slack`.
- Adapters started via `connect/1`; `:permanent` restart strategy.
- `adapter_for/1` — returns adapter module for a provider string or `nil`.

### Channel Adapter Loader (`Zaq.Engine.ChannelAdapterLoader`)

- Shared helper used by both supervisors.
- `children_for/3` — loads enabled configs, maps providers to adapter modules, builds
  Supervisor child specs.
- `load_configs/4` — queries `ChannelConfig.list_enabled_by_kind/2`; logs and returns `[]`
  when no configs found.
- `build_child_spec/5` — returns `[]` (with warning) for unknown providers.

For telemetry modules (`Zaq.Engine.Telemetry`, `Buffer`, `Collector`, workers), see `docs/services/telemetry.md`.

### Schemas

**`Zaq.Engine.Conversations.Conversation`** (`conversations`)

- Fields: `title`, `channel_user_id`, `channel_type`, `channel_config_id`, `status`,
  `metadata`, `user_id`.
- Valid channel types: `mattermost`, `slack`, `bo`, `api`.
- Valid statuses: `active`, `archived`.
- Primary key: UUID (`:binary_id`).

**`Zaq.Engine.Conversations.Message`** (`messages`)

- Fields: `role`, `content`, `model`, `prompt_tokens`, `completion_tokens`,
  `total_tokens`, `confidence_score`, `sources`, `latency_ms`, `metadata`.
- Valid roles: `user`, `assistant`.
- No `updated_at` timestamp.

**`Zaq.Engine.Conversations.MessageRating`** (`message_ratings`)

- Fields: `rating` (1–5), `comment`, `channel_user_id`, `user_id`, `person_id`, `message_id`.
- Unique constraints on `(message_id, user_id)` and non-null `(message_id, person_id)`.
  Person authors are mutually exclusive with BO/channel attribution. Merges retain
  survivor feedback on conflicts and transfer uncontested Person ratings.

**`Zaq.Engine.Conversations.ConversationShare`** (`conversation_shares`)

- Fields: `share_token` (auto-generated, URL-safe base64), `permission` (only `"read"`),
  `expires_at`, `shared_with_user_id`.
- Unique constraints on `share_token` and `(conversation_id, shared_with_user_id)`.

For telemetry schemas (`Point`, `Rollup`) and dashboard contracts, see `docs/services/telemetry.md`.

**`Zaq.Engine.DataSources.WatchChannel`** (`data_source_watch_channels`)

- Fields: `config_id`, `provider`, `target_source`, `target_provider_id`, `target_kind`,
  `channel_id`, `resource_id`, `resource_uri`, `checkpoint`, `expiration_at`, `status`,
  `last_error`, `metadata`.
- Valid target kinds: `file`, `folder`, `collection`.
- Valid statuses: `active`, `error`, `stopped`.
- Unique constraint on `(provider, channel_id)`.

---

## Files

```
lib/zaq/engine/
├── conversations/
│   ├── conversation.ex               # Ecto schema: conversations table
│   ├── conversation_share.ex         # Ecto schema: conversation_shares table
│   ├── message.ex                    # Ecto schema: messages table
│   ├── message_rating.ex             # Ecto schema: message_ratings table
│   ├── title_generator.ex            # Async LLM-based conversation title generation
│   └── token_usage_aggregator.ex     # Oban worker: daily token usage rollup per model
├── messages/
│   ├── incoming.ex                   # Canonical inbound message struct
│   └── outgoing.ex                   # Canonical outbound message struct
├── notifications/
│   ├── email_notification.ex         # SMTP email delivery via Swoosh
│   ├── notification.ex               # Notification struct + build/1 validation
│   ├── notification_log.ex           # Ecto schema + audit trail for notifications
│   ├── password_reset_email.ex       # Password reset email builder/dispatcher
│   └── welcome_email.ex              # Welcome email builder/dispatcher
├── telemetry/                        # See docs/services/telemetry.md
├── channel_adapter_loader.ex         # Shared child-spec builder for supervisors
├── conversations.ex                  # Public API: conversations/messages/ratings/shares
├── data_sources.ex                   # Provider watch-channel runtime coordination
├── data_sources/                     # WatchChannel schema and renewal worker
├── ingestion_channel.ex              # Behaviour contract for ingestion adapters
├── ingestion_supervisor.ex           # Supervises ingestion channel adapter processes
├── notification_channel.ex           # Behaviour contract for notification adapters
├── notifications.ex                  # Public API: notify/1 dispatch pipeline
├── retrieval_channel.ex              # Behaviour contract for retrieval adapters
├── retrieval_supervisor.ex           # Supervises retrieval channel adapter processes
├── supervisor.ex                     # Top-level supervisor for the :engine role
└── telemetry.ex                      # See docs/services/telemetry.md
```

---

## Configuration

SMTP configuration is read from `ChannelConfig` for provider `"email:smtp"`.

For all `telemetry.*` system config keys, see `docs/services/telemetry.md`.

Oban queues used by the Engine:

- `:conversations` — token usage aggregation
- `:channels` — data-source watch-channel renewal provider calls
- `:telemetry` and `:telemetry_remote` — see `docs/services/telemetry.md`

---

## Key Design Decisions

- **NodeRouter for cross-node calls** — BO LiveViews never call `Conversations` directly;
  all calls are routed via `NodeRouter` (prefer `dispatch/1`).
- **Notification payload stored in DB** — subject/body are stored in `NotificationLog`
  before inline delivery attempts so audit records survive delivery failures.
- **Notification dispatch is inline** — callers receive the final sent/skipped/failed status
  and, on success, the channel that was actually used.
- **Atomic JSONB append** — `NotificationLog.append_attempt/4` uses a raw Postgres `||`
  fragment for delivery-attempt audit trails.
- **Conversation title is generated async** — `Task.start/1` so title generation never
  blocks message persistence; title update is broadcast on PubSub.
- **Engine owns provider watch runtime state** — Channels may be DB-less, so provider
  watch-channel ids, checkpoints, expiration, and renewal state live in Engine.
- **Token aggregation via Oban** — `TokenUsageAggregator` enqueues a job per assistant
  message; aggregation is idempotent (overwrites the day's model bucket on each run).
- **Channel adapters registered at compile time** — `IngestionSupervisor` and
  `RetrievalSupervisor` hold a `@adapters` module attribute mapping provider strings
  to adapter modules; adding a new adapter requires only a map entry plus a DB config row.

---

## What's Left

### Should Do

- [ ] Dynamic adapter hot-loading — currently adapters are resolved only at supervisor
      startup; adding/removing a ChannelConfig requires an Engine node restart.
- [ ] Conversation pruning — no lifecycle management for old conversations; storage grows
      unbounded.

### Nice to Have

- [ ] Notification channel adapter for Slack/Mattermost direct messages
