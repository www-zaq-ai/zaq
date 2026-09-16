# People permissions

People capabilities are explicit grants managed in **BO → People → Permissions**.
They are distinct from resource rights (`Zaq.Permissions`) and BO user roles.
The migration creates no grants: the initial state is default deny.

## Storage and scopes

`Zaq.Accounts.PeoplePermissionGrant` stores `people_permission_grants`:
an integer ID, `scope_type`, nullable `scope_id`, `permission`, and UTC timestamps.
Scopes are `:all_people` or `{:team, team_id}`. Global grants have no scope ID;
team grants reference an existing team and cascade when that team is deleted.
Database checks enforce the closed scope/permission vocabulary and scope-ID shape.
Separate partial unique indexes enforce one grant per global permission and one
per team/permission, including real uniqueness for global rows with NULL scope IDs.
The team index also supports team-scope lookups via its leading scope ID.

The schema owns the ordered permission metadata and explicit atom/string casting:

| API atom / storage string | Matrix label           |
| ------------------------- | ---------------------- |
| `access_profile`          | Access profile         |
| `access_message_history`  | Access message history |
| `share_conversations`     | Share conversations    |

Only these exact strings or known atoms are accepted. Input never creates atoms.

## Resolution API

`Zaq.Accounts.PeoplePermissions` owns grant persistence and resolution:

- `effective_permissions(person)` returns a `MapSet` of permission atoms: the
  union of all global grants and grants on the supplied Person's current team IDs.
- `allowed?(person, permission_or_permissions)` checks raw membership for a single
  permission or **ALL** permissions in a nonempty list. Known atoms and exact storage
  strings can be mixed; duplicates and order do not matter. Effective grants resolve
  once per valid call, without an additional Person query. Empty lists deliberately
  return `false`; unknown permissions (even in mixed lists), malformed or improper
  lists, nested lists, and nil also deny.
- `list_grants()` returns persisted explicit grants, ordered by ID.
- `grant(scope, permission)` atomically inserts or returns the existing row as
  `{:ok, grant}`. A scoped conflict update preserves its ID and timestamps.
- `revoke(scope, permission)` deletes only that explicit grant and returns
  `{:ok, deleted_count}`; zero is successful and repeated requests are idempotent.
- `permissions_matrix()` returns `%{scopes: columns, rows: rows}`. Columns have
  `scope` and `label`; rows have `permission`, `label`, and a `grants` MapSet of
  explicit scopes. All People comes first, then current teams ordered by name,
  including teams without grants. Permission rows use the schema's stable order.

Resolve identity through `Zaq.Accounts.People.get_person/1` first, including merged
aliases. Predicates accept only loaded, persisted Person structs and use their
supplied current team IDs without re-querying identity. Nil, missing identity,
transient structs, and invalid permissions fail closed. Callers must discard stale
identity/team data when resolution fails. Person status does not change grant
semantics. No cache or implicit prerequisite grants are used.
Each caller operation declares its own requirements: `allowed?(person,
:share_conversations)` checks only the share grant; `allowed?(person,
[:access_profile, :access_message_history, :share_conversations])` explicitly
requires all three. The context does not infer operation prerequisites.

Invalid write coordinates return `{:error, :invalid_scope}` or
`{:error, :invalid_permission}`. Database validation failures return
`{:error, changeset}` with named field constraints, including deleted team IDs.
Removing a global grant does not remove overlapping team grants; team membership
changes take effect when the caller supplies the current resolved Person.

## BO and Engine boundary

PeopleLive uses its existing `people_command` helper and
`Zaq.Engine.Events.build_and_dispatch_invoke_event/3` through NodeRouter.
Engine's `:people_command` action delegates to `Zaq.Engine.PeopleGateway` operations
`:permissions_matrix`, `:grant_permission`, and `:revoke_permission`.
Writes carry `%{scope: scope, permission: permission}`; matrix reads need `%{}`.

The matrix shows explicit cells, not inherited permissions. Each Switch submits
an explicit desired boolean state. Browser scopes and permission strings must
match the canonical scope/permission vocabulary. Browser scopes must name a current
matrix column; the context write boundary validates permission membership. Missing
or non-boolean desired states are rejected.
Share can be on while history is off; its raw grant check succeeds independently.
A caller's explicit list check denies when any requested grant is missing.
Every write reloads authoritative state. A write
failure is visible; a failed reload removes stale controls and offers a retry.
Each completed attempt, including malformed browser events, refreshes authority.
A presentation generation updates the stable matrix wrapper on refresh. Its
People-specific hook restores native checkbox properties from server-rendered
`aria-checked`, even when the database result is identical to the prior assign.
Cell IDs, focus, and scroll position are retained; permission data contains no UI
synchronization state.

Administration uses the existing authenticated BO People access policy. These
grants do not authorize BO administrators. People authentication separately
requires an active current Person with `access_profile`; BO sessions are independent.
There are no public People login, profile, history, sharing or portal routes yet.

## People access configuration (current)

**BO → System Configuration → People access** (`/bo/system-config?tab=people_access`)
manages the following settings consumed by PeopleAuth and AuthRateLimiter.
Authenticated BO access policy is independent.
OTP length is fixed at eight digits, not configurable.

`Zaq.System.PeopleAccessConfig` is the embedded schema and single source of defaults.
All fields are strictly positive integers; durations use seconds, limits use counts.
There are no product maxima or cross-field restrictions.

| Field (key suffix)             | Default | Unit / duration      |
| ------------------------------ | ------: | -------------------- |
| `otp_validity_seconds`         |     300 | seconds / 5 minutes  |
| `otp_max_attempts`             |       5 | attempts per OTP     |
| `unknown_email_attempt_limit`  |      10 | attempts             |
| `unknown_email_window_seconds` |     600 | seconds / 10 minutes |
| `otp_send_person_limit`        |       5 | sends per person     |
| `otp_send_ip_limit`            |      20 | sends per IP         |
| `otp_send_window_seconds`      |     900 | seconds / 15 minutes |
| `session_lifetime_seconds`     |  604800 | seconds / **7 days** |

Storage uses numeric strings in the existing `system_configs` table, prefixed with
`people_access.`. No environment settings apply to these eight controls. The legacy
`people_access.unknown_email_cooldown_seconds` key, if present, is ignored and left
untouched by reads/saves. There is no independent cooldown: retry waits only for the
current failed-identification window to expire.

- `Zaq.System.get_people_access_config/0` returns `{:ok, %PeopleAccessConfig{}}`
  using one grouped SELECT. Missing keys receive schema defaults without writes.
  Corrupt stored values return `{:error, {:invalid_people_access_config, changeset}}`;
  invalid values never silently fall back to defaults.
- `Zaq.System.save_people_access_config(attrs)` validates attributes itself and
  atomically upserts all eight keys using `Ecto.Multi`. Success returns the typed
  saved config; invalid input or persistence failure returns `{:error, changeset}`.
  Partial input preserves current effective values (including for an empty map).
  Corrupt stored configuration blocks partial saves with the typed read error;
  a complete valid payload can repair the group. Concurrent editors have
  last-complete-save-wins behavior, without conflict detection.
- Known atom/string keys are accepted; atom keys win duplicate representations.
  Unknown keys are ignored and never written or converted to atoms. Integer strings
  must parse completely; floats, fractions, trailing junk, blanks, nil, zero,
  negatives, booleans, maps, and lists are rejected as field values. Client-supplied
  changesets are rejected, not trusted as validated input.
- Engine actions `:system_config_get_people_access_config` and
  `:system_config_save_people_access_config` (request `%{attrs: attrs}`) delegate
  to System. BO uses the existing Engine Events/NodeRouter boundary.

The form groups OTP, Unknown email protection, OTP sends, and Sessions into one
Save. Validation errors are inline and failed saves retain edits. Failed/corrupt
loads show an explicit error and Retry, disable Save, and omit editable defaults;
the form becomes editable only after an authoritative successful load.

## People authentication backend

`Zaq.Accounts.PeopleAuth` owns the lifecycle on Engine nodes. These are trusted
backend APIs, not public routes or Engine event operations. No notification is
dispatched. A delivery caller must not expose the returned OTP to a browser or
place codes/tokens in generic event envelopes, logs or persisted notification data.

| Operation                                          | Success contract                                                                                                  |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `issue_challenge(person_or_id, ip, opts \\ [])`    | `{:ok, %{challenge_id: uuid, code: eight_digits, expires_at: datetime}}`; code returned once for trusted delivery |
| `verify_challenge(challenge_id, code, opts \\ [])` | `{:ok, %{token: bearer, session: metadata}}`; consumes challenge and creates session atomically                   |
| `authenticate(token, opts \\ [])`                  | `{:ok, %{person: current_person, session: metadata}}`                                                             |
| `touch_session(token, opts \\ [])`                 | `{:ok, metadata}`; checks authentication and records `last_seen_at`, without extending expiry                     |
| `revoke_session(token)`                            | `{:ok, metadata}`; idempotent for an existing session                                                             |
| `list_sessions(person_or_id)`                      | `{:ok, [metadata]}`; includes expired/revoked sessions, ordered by UUID                                           |
| `invalidate_challenges(person_or_id)`              | `{:ok, count}`; invalidates all unfinished challenges, including expired ones                                     |
| `revoke_all_sessions(person_or_id)`                | `{:ok, count}`; revokes all unrevoked sessions, including expired ones                                            |

Person inputs are persisted Person structs or positive integer IDs. Trusted
Person-based operations resolve aliases through `People.get_person/1` and lock the
current row; missing/deleted identities return `{:error, :not_found}`. Issuance,
verification, authentication and touch require current active status and
`PeoplePermissions.allowed?(person, :access_profile)`. No nil identity or implicit
permission bypass exists. Session metadata contains only `id`, `expires_at`,
`revoked_at`, `last_seen_at`, and `inserted_at`. A session UUID is not a bearer token;
list/revoke-all/invalidate take trusted owner coordinates, not proof of authority.

The public-safe challenge descriptor is only `challenge_id` and `expires_at`.
Verification accepts that opaque UUID, not a Person identifier. Invalid, expired,
consumed, invalidated, exhausted or ineligible challenges return
`{:error, :invalid_challenge}`. Whitespace and hyphens are removed from code input;
the result must be exactly eight ASCII digits. Malformed/wrong guesses on a live
eligible challenge commit an attempt, capped by the current configured maximum.
Non-live challenges do not accrue attempts. Only one concurrent verifier receives
a session token. Failed session persistence rolls back challenge consumption.

Invalid/expired/revoked/ineligible sessions return `{:error, :invalid_session}`.
Issuance returns `{:error, :ineligible}` for a known ineligible Person. All fallible
operations return tagged errors; callers must not treat an error tuple as truthy
authorization. Corrupt typed settings propagate the explicit config error for
issuance, verification, authentication and touch. Revocation and owner listing do
not load auth config or check eligibility. Config reads do not silently fall back.
Challenge/session expiry is fixed when issued, while changed attempt limits apply
to in-flight challenges. Unrepresentable calendar expiry fails with `:invalid_expiry`.

### Storage, cryptography and merges

`person_login_challenges` and `person_sessions` use UUID primary keys, integer
Person foreign keys with delete cascades, UTC timestamps, and 32-byte binary
`token_digest` fields marked redacted in Ecto. No plaintext credential fields exist.
Challenges have `expires_at`, nonnegative `attempt_count`, `consumed_at` and
`invalidated_at`; consumption and invalidation are mutually exclusive. A partial
unique index allows one unfinished challenge per Person, even when expired.
Issuance invalidates all unfinished rows before inserting a replacement. Sessions
have unique token digests, `expires_at`, `revoked_at` and `last_seen_at`. Both tables
index Person and expiry; sessions also index non-null revocation. Database checks
enforce digest length, lifecycle shape and expiry after insertion.

OTP generation uses cryptographic 32-bit rejection sampling over `0..99_999_999`,
padded to eight digits. The key is derived by `Plug.Crypto.KeyGenerator.generate/3`
from the existing configured endpoint `secret_key_base`, with length 32 and purpose
**`zaq:people-auth:otp-verification:v1`**. HMAC-SHA256 covers
`challenge_uuid <> ":" <> eight_digit_code`; fixed formats avoid ambiguity.
Verification uses `Plug.Crypto.secure_compare/2`. The base must be a binary of at
least 64 bytes; otherwise issuance/verification return `:invalid_signing_configuration`.
There is no new secret-management API or persisted signing key. The endpoint's
runtime application configuration is available on Engine-only nodes too. Trusted
runtime opts support the existing `secret_key_base` override convention, `config`
through `Zaq.Config`, and a `clock` implementing `utc_now(:second)`.

Session tokens encode 32 cryptographically random bytes as unpadded URL-safe
Base64; only SHA256 of the encoded bearer is stored. Rotating `secret_key_base`
invalidates outstanding OTP verification, but not these independent session digests.
Authentication SQL/telemetry receives only digests and opaque/owner coordinates.

Person locks precede challenge/session locks. The merger locks all participants in
stable ID order, snapshots auth resources and validates planned revocations before
writes, then uses ordinary invalidation/revoke-all APIs. **All participants,
including the survivor, lose their challenges and sessions.** Loser rows cascade
on deletion; survivor rows retain invalidation/revocation timestamps. Credentials
are never transferred or recovered through aliases. Outer transaction failure
restores the entire merge, including auth rows. Authentication revocation requires
no signing configuration or running rate-limiter process.

Migration `20260910160000_create_person_authentication.exs` intentionally precedes
`20260910194115_normalize_person_emails.exs`: that historical data migration invokes
the current merger. Existing applied migrations are unchanged. Upgrades must run
ordinary `mix ecto.migrate` to apply the pending earlier-numbered version; do not
use strict version ordering for this upgrade. Fresh replay therefore has auth
tables before normalization, without schema-discovery fallbacks or bypass options.

### Rate topology and retry behavior

Rate ownership is split by role, after shared PubSub:

| Owner    | Runtime / API                                                                                                   | Budget                                     |
| -------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Engine   | `Zaq.People.AuthRateLimiter` under `Engine.Supervisor`; `reserve_challenge/2`                                   | OTP issuance/resend per Person and IP      |
| Channels | `Zaq.Channels.PeopleAuthRateLimiter` under the static `Channels.Supervisor`, before `Channels.BridgeSupervisor` | Unsuccessful-identification IP budget only |
| Engine   | `PeopleAuth.verify_challenge/3` and persisted challenge row                                                     | Current configured verification maximum    |

The shared `Zaq.People.AuthRateLimiter` supervisor implementation starts one instance
per owner: Engine keeps its existing name; Channels uses
`Zaq.Channels.PeopleAuthRateLimiter.Runtime`. Tables are respectively
`Zaq.People.AuthRateLimiter.Local` and `Zaq.Channels.PeopleAuthRateLimiter.Local`;
listeners use the corresponding `.Listener` names. PubSub topics are
`zaq:people_auth:issuance:v1` and `zaq:people_auth:identification:v1`.
Combined-role nodes start both once, without sharing counters or adapter lifecycle.
The Channels parent uses `:one_for_one`: bridge runtime restarts preserve the
limiter; restarting the whole limiter resets its local counters and config cache
without restarting bridges. Parent shutdown stops both subtrees.

Dependency **Hammer 7.5.0** provides built-in `Hammer.ETS` fixed windows. Its local
counter and application-owned listener follow the official
[distributed ETS guide](https://hexdocs.pm/hammer/7.5.0/distributed-ets.html).
The adapter broadcasts increments to remote nodes only; the listener applies
`Local.inc`, and the initiating node uses `Local.hit`. No cooldown/reset protocol,
SQL counter store, Redis dependency or replicated state framework is involved.

- Channels `check_identification(ip)` returns `:ok` or `{:error, {:rate_limited, retry_ms}}`
  without consuming quota. The future authentication caller must invoke it locally
  **before Engine dispatch** and deny dispatch on any error.
- Channels `record_failed_identification(ip)` records only unknown/ineligible identification.
  The first configured N failures are counted; subsequent prechecks block until
  window expiry. Known successful requests never call this operation.
- Engine `reserve_challenge(person_id, ip)` reserves the separate Person then IP send
  budgets, after eligibility passes. Both new issuance and resend use it. An
  accepted reservation is not refunded on a later quota or database failure.
  Hammer also counts denied hits; these do not extend the window.

Engine reservations load the current typed config group. Channels operations read
only a local typed snapshot from `PeopleAuthRateLimiter.Config`; they never query
Repo or dispatch an Engine/config request. The cache loads via the existing
`:system_config_get_people_access_config` Engine action at startup, then refreshes
30 seconds after each completed fetch. A snapshot expires 120 seconds after its
fetch started, even if the next fetch is stuck. Cold/missing/expired snapshots deny
with `:rate_limiter_unavailable`; any failed or corrupt refresh removes the snapshot
immediately. Successful refresh recovers availability without resetting counters.
Cache restart also leaves counters intact. These timing constants are operational
code constants, not additional product settings. Normal configuration updates take
effect on the next completed refresh, not synchronously with Save.

The keys contain owner, purpose,
trusted IPv4/IPv6 tuple or Person ID, and window scale; email strings are never keys.
Malformed IPs return `:invalid_ip`, invalid send Person IDs `:invalid_person`, and
missing rate infrastructure `:rate_limiter_unavailable`. Runtime limit changes use
current counts; window changes select another scale-specific bucket and do not
rewrite older buckets. Reverting a window can revisit its still-live bucket.

`retry_ms` is the native remaining fixed-window duration. Expiry restores budget;
there is no independent cooldown control or timer. Windows align to wall-clock
boundaries and permit boundary bursts. Counters are **eventually consistent**, not
an exact cluster-wide quota: simultaneous requests can overshoot, new/restarted
nodes begin empty, and partitions lose increments with no replay/state transfer.
Delayed hits are applied in the receiving node's current window. Clock differences
can change bucket attribution. No hard global overshoot bound is promised.

### PR4 integration boundary (not implemented)

V1 exposes the supervised budgets and trusted Person/ID-based backend lifecycle;
it does not add an email challenge request, authentication Engine event, gateway,
public route, cookie or notification delivery. PR4 must compose: local Channels
precheck → **one** Engine request resolving identity, checking eligibility and
issuing → Channels records a failure only for the unknown/ineligible outcome in
that response. Identity lookup stays in Engine. There is no two-phase lookup/issue
protocol or callback from Engine to Channels for rate accounting. Delivery must
keep raw OTPs out of public responses. There is **no broad ingress ceiling**:
known eligible requests may reach Engine and be rejected by issuance budgets.
