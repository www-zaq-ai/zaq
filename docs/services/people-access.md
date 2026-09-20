# People permissions

People capabilities are explicit grants managed in **BO → People → Permissions**.
They are distinct from resource rights (`Zaq.Permissions`) and BO user roles.
The migration creates no grants: the initial state is default deny.

## Storage and scopes

`Zaq.Accounts.PeoplePermissionGrant` stores `people_permission_grants`:
an integer ID, `scope_type`, required `scope_id`, `permission`, and UTC timestamps.
Scopes are `:everyone` or `{:team, team_id}`. Both are stored as team grants with a
scope ID and cascade when that team is deleted. `:everyone` resolves the synthetic
team identified by `system_key: "everyone"`; it is not inferred from its name or ID.
Database checks enforce the closed scope/permission vocabulary and scope-ID shape.
A partial unique index enforces one grant per team/permission and supports
team-scope lookups via its leading scope ID.

The schema owns the ordered permission metadata and explicit atom/string casting:

| API atom / storage string | Matrix label           |
| ------------------------- | ---------------------- |
| `access_profile`          | Access profile         |
| `edit_profile`            | Edit profile           |
| `manage_credentials`      | Manage credentials     |
| `access_message_history`  | Access message history |
| `share_conversations`     | Share conversations    |

Only these exact strings or known atoms are accepted. Input never creates atoms.

## Resolution API

`Zaq.Accounts.PeoplePermissions` owns grant persistence and resolution:

- `effective_permissions(person)` returns a `MapSet` of permission atoms: the
  union of Everyone grants and grants on the supplied Person's current team IDs.
  Everyone applies to every valid persisted Person without adding synthetic team
  membership to the Person record.
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
  explicit scopes. Everyone appears once and first, then ordinary teams ordered by
  name, including teams without grants. Permission rows use the schema's stable order.

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

Credential self-service reads use the authenticated session's required
`access_profile`; credential writes and OAuth authorization explicitly require both
`access_profile` and `manage_credentials`. The migration adds no grants.

Invalid write coordinates return `{:error, :invalid_scope}` or
`{:error, :invalid_permission}`. Database validation failures return
`{:error, changeset}` with named field constraints, including deleted team IDs.
Removing an Everyone grant does not remove overlapping team grants; team membership
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
Public People login, profile and owned conversation history are available on
Channels nodes. BO sessions and administration remain independent.

## Self-service conversation history

`/people/history` and `/people/conversations/:id` share the existing protected
People live session. The enhanced PersonHeader keeps its logo, theme and account
controls; Settings adds Conversations when both profile and history grants exist.
The full-page BO HistoryBrowser and ConversationDetail presentation are shared,
with People-specific routes and explicit capabilities. People has no identity
selectors, selection, archive or delete actions. BO remains unpaged.

The confidential fixed Engine `:people_conversations` action delegates to
`PeopleConversations`. Each operation authenticates its server-held bearer and
checks `allowed?(person, [:access_profile, :access_message_history])`. Sharing,
including listing existing links, additionally requires `share_conversations`.
Owner and author coordinates never come from browser attributes. Parent queries
bind UUID and literal current Person before loading messages, shares or artifacts;
malformed, foreign and missing IDs are indistinguishable. Legacy unassociated
conversations are not inferred or backfilled by self-service.

History defaults to all active and archived owned conversations, optionally
filtered by status/channel. SQL count and bounded 25-row pages use identical
filters and deterministic updated-at/UUID ordering. Known local filter/page
parameters round-trip through the list/detail Back destination.

Ratings use nullable `message_ratings.person_id` with a partial unique
message/Person index. Person authors cannot coexist with BO/channel attribution.
People loads only its current author's rating; anonymous BO behavior remains.
Outer transactions retain authentication Person/session locks through writes,
then lock the conversation parent. Merges preserve the survivor's rating when
both participants rated a message; otherwise lowest original Person/UUID wins.
Uncontested ratings transfer through ordinary rating APIs before loser deletion.
Migration `20260910170000_add_person_to_message_ratings.exs` intentionally precedes
historical email normalization, like the authentication schema. Use ordinary
migration ordering rather than strict-version mode; historical migrations are unchanged.
The separate `20260915142546_add_conversation_person_activity_index.exs` migration
indexes literal ownership plus activity/UUID ordering for bounded history pages.

Fresh schema/data replay is available through
`test/support/people_history_migration_replay.exs`, run with `MIX_ENV=test` and a
unique `MIX_TEST_PARTITION=_people_history_replay_<suffix>` using `mix run --no-start`.
Use a short suffix (for this worktree, six hex characters) to stay within
PostgreSQL's 63-byte database-name limit; oversized names are rejected.
It refuses existing databases and retains its new isolated database; it never
resets or drops one. The Repo-only replay covers prerequisite ordering, failed
normalization rollback, rating conflicts/transfers, session revocation and reruns.

Citation and artifact URLs bind conversation and message parents, use People
authentication, and return private/no-store sandboxed responses. Citation reads
require an exact stored message citation. Engine returns that reference and a fresh
actor normalized from the authenticated Person; it does not fetch document metadata
or bytes. The Channels-hosted controller executes `GetDocument` through `Jido.Exec`
using that actor, enforcing current Records access through the existing data-source
boundary. The modal and controller share `ZaqWeb.PersonConversationResource` for
this orchestration. It redeems only the freshly returned Record's handle directly with
the owning role (or serves its already-materialized content). Ingestion indexes
documents and embeddings; indexed Document rows, cached content and persisted handles
are not dependencies of this resource-read path.

Canonical citation identities are `data_source/<provider>/<config>/<record-id>`;
the record ID retains embedded slashes verbatim. Missing namespaces/configs are
rejected, not inferred from local paths or browser provider fields. Handles never
become browser preview credentials. Trace JSON is displayed unchanged. Captured trace
artifacts require their owning conversation, message and trace reference; access to
that owned conversation authorizes its immutable captured bytes without interpreting
historical Record metadata or rechecking the source. Citation previews are different:
they always use `GetDocument` to obtain a fresh authorized Record and materialize only
that Record, so removed or newly inaccessible sources fail closed. Public `/s/:token`
links retain existing token/expiry semantics and do not grant People authentication
or resource access.

## Self-service profile

`/people/profile` displays full name, email, phone, role, status, team names and
owned channel platform/identifier/priority. Reading requires an active current
Person and `access_profile`. Every edit explicitly requires
`PeoplePermissions.allowed?(person, [:access_profile, :edit_profile])`.
These independent grants may come from different scopes. Granting edit does not
grant access, and existing access grants do not permit any edits.

Only `full_name` and owned channel `weight` are editable. `Person.self_profile_changeset/2`
casts only the name and recalculates completeness. Clearing the optional name stores
an empty string, compatible with the database's non-null column. Email, phone, role,
status, teams, metadata and identity history cannot be changed through self-service.
`PersonChannel.weight_changeset/2` casts only weight: a nonnegative integer within
the existing PostgreSQL integer storage range. Lower weights are tried first;
ties use ascending channel ID. Priority edits preserve identity, ownership, metadata
and `last_interaction_at`; they do not record communication activity.

Trusted persistence APIs are `People.update_self_profile(person, attrs)` and
`People.update_self_channel_weight(person, channel_id, attrs)`. The latter queries
by both literal current Person ID and channel ID before reading or updating.
Foreign, missing and discarded channel IDs return `:not_found`, without alias fallback.
Browser callers use fixed confidential `:people_auth` Engine operations `:profile`,
`:update_self_profile`, `:update_self_channel_weight` and `:update_self_channel_order`,
never trusted owner coordinates.
`PeopleAuthGateway` delegates these operations to `PeopleProfile`, which derives the
current Person from its bearer and owns profile authorization and projection. It holds
authentication's Person-before-session locks in an outer transaction through each
write and fresh response. This serializes writes with session revocation and merges;
merged credentials cannot transfer. Grant changes are checked at each operation
boundary, but grant administrators do not participate in the Person lock protocol.

`People.update_self_channel_order(person, ids, expected)` replaces all owned channel
priorities atomically. `ids` is a complete permutation of the current literal owner's
integer channel IDs; duplicates, omissions, foreign IDs and malformed lists reject.
`expected` is the original ordered list of `%{id: integer, weight: integer}` maps.
Different current membership, ordering or weights returns `:stale_order` before
writing. The transaction locks the literal Person `FOR UPDATE`, then its channels
by ID `FOR UPDATE`, and compares the fresh weight/ID-sorted snapshot. Person/FK
locking blocks new channel references; channel locks serialize existing updates
and deletes, including the legacy single-weight API. Merges already use Person-first
locking. Dense zero-based weights go through `weight_changeset/2`; all rows commit
or roll back together, preserving metadata and activity. The confidential gateway
adds the same authentication/edit authorization and fresh response as existing writes.

BO `People.swap_channel_weights/2` also locks literal Person owners first (ascending
ID for trusted cross-owner swaps), then the requested channels in ascending ID order.
It rereads current weights under those locks instead of using the supplied structs'
old weights. Missing owners/channels or changed ownership return `:not_found` without
alias fallback or partial writes. Existing cross-owner behavior, success envelope
and ordinary channel-update activity semantics are retained. Thus a BO swap waiting
for a profile reorder swaps the newly committed weights; a profile draft waiting
for a BO swap rejects its now-stale snapshot.

The profile uses the approved wide PersonLayout and shared PersonHeader/account menu;
login retains the default narrow shell. Real full name (safe Profile fallback),
People Profile and People logout are used; Settings includes Conversations when history access is granted.
Teams are alphabetical and read-only. Provider icons and numbered channel rows replace
numeric forms. One inline editor at a time offers name Save/Cancel or channel-order
Save/Cancel with optional dragging and move-button alternatives. The draft and expected
snapshot stay server-owned; Save dispatches one atomic operation. Validation keeps
submitted scalar values and shows field errors; success reloads authoritative data.
The existing optional blank-name behavior is retained. Stale order reloads for explicit
review without overwriting or claiming success. Transient save errors retain drafts
when a fresh authorized read confirms safe retry; failed reads remove controls.
Database/transport exceptions at the web command boundary become generic unavailable
outcomes without logging exception data. The live profile uses presentational
`PersonProfile` and pure web `ChannelOrder`; the retired fixture preview is removed.
Edit revocation denies the next save and refreshes the page read-only, retaining
profile access. Access/session invalidation redirects to login. Unavailable loads
remove writable controls; authentication/configuration failures show unavailable
feedback and fail closed. The server-held bearer stays in socket private state,
never assigns, DOM, URLs or client parameters. Profile responses exclude metadata,
merge history, internal DM IDs and authentication credentials. Navigation contains
Profile, Sign out and permission-gated Conversations in Settings; BO credentials remain independent.

Migration `20260914153303_add_edit_profile_permission.exs` replaces only the known
permission CHECK and preserves existing grants. Downgrade refuses while edit grants
exist; operators must explicitly revoke them before reverting the vocabulary.

## People access configuration (current)

**BO → System Configuration → People access** (`/bo/system-config?tab=people_access`)
manages the following settings consumed by PeopleAuth and AuthRateLimiter.
Authenticated BO access policy is independent.
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

`Zaq.Accounts.PeopleAuth` owns the lifecycle on Engine nodes. Its Person/ID-based
APIs are trusted backend APIs. Public callers use the fixed `:people_auth` Engine
action and `PeopleAuthGateway`; BO administration uses the allowlisted
`:people_command` operations `:list_person_sessions`, `:revoke_person_session`,
and `:revoke_all_person_sessions` through NodeRouter. The gateway delivers through
Notifications and returns only a public descriptor.
Bearer/OTP events are confidential. V1 intentionally accepts existing notification
body persistence; authentication tables remain digest-only.

| Operation                                          | Success contract                                                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `issue_challenge(person_or_id, ip, opts \\ [])`    | `{:ok, %{challenge_id: uuid, code: eight_digits, expires_at: datetime, resend_available_at: datetime}}`; code returned once for trusted delivery |
| `verify_challenge(challenge_id, code, opts \\ [])` | `{:ok, %{token: bearer, session: metadata}}`; consumes challenge and creates session atomically                                                  |
| `authenticate(token, opts \\ [])`                  | `{:ok, %{person: current_person, permissions: current_grants, session: metadata}}`                                                               |
| `revoke_session(token)`                            | `{:ok, metadata}`; idempotent for an existing session                                                                                            |
| `list_sessions(person_or_id, opts \\ [])`           | `{:ok, [metadata]}`; defaults to all rows, or `active_only: true` for unrevoked sessions whose expiry is strictly in the future; ordered by insertion time and UUID |
| `invalidate_challenges(person_or_id)`              | `{:ok, count}`; invalidates all unfinished challenges, including expired ones                                                                    |
| `invalidate_challenge(challenge_id)`               | `{:ok, count}`; targeted trusted delivery cleanup, missing/finished rows return zero                                                             |
| `challenge_status(challenge_id, opts \\ [])`       | current eligibility/lifecycle/expiry/attempt check; returns only a safe descriptor                                                               |
| `revoke_all_sessions(person_or_id)`                | `{:ok, count}`; revokes all unrevoked sessions, including expired ones                                                                           |

Person inputs are persisted Person structs or positive integer IDs. Trusted
Person-based operations resolve aliases through `People.get_person/1` and lock the
current row; missing/deleted identities return `{:error, :not_found}`. Issuance,
verification and authentication require current active status and
`PeoplePermissions.allowed?(person, :access_profile)`. No nil identity or implicit
permission bypass exists. Session metadata contains only `id`, `expires_at`,
`revoked_at`, `last_seen_at`, and `inserted_at`. A session UUID is not a bearer token;
list/revoke-all/invalidate take trusted owner coordinates, not proof of authority.

Owner-targeted single-session revocation requires both the canonical Person and
session UUID, returns `:not_found` for missing or foreign sessions, and is
idempotent for an already revoked row. Owner listing and revocation are independent
of eligibility and auth configuration. The BO displays only active metadata
(Created, Last activity, Expires); it makes no realtime eviction promise, so an
already authenticated request may remain valid until its next backend check.

The public-safe challenge descriptor contains `challenge_id`, `expires_at` and
`resend_available_at` (UTC datetimes). The resend deadline is always insertion + 60
seconds, independent of the configured OTP validity (default 300 seconds).
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
issuance, verification and authentication. Revocation and owner listing do
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
| Engine   | `PeopleAuth` issuance policy using `Zaq.People.AuthRateLimiter` mechanics under `Engine.Supervisor`              | OTP issuance/resend per Person and IP      |
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
- Engine `PeopleAuth` reserves the separate Person then IP send budgets, after
  eligibility passes, through the generic limiter counter API. Both new issuance
  and resend use it. An
  accepted reservation is not refunded on a later quota or database failure.
  Hammer also counts denied hits; these do not extend the window.

Before reserving send budgets, PeopleAuth checks the newest unfinished challenge
under the existing Person lock, after eligibility. Issuance—including repeated
initial email POSTs—requires at least 60 elapsed seconds from `inserted_at`.
Expired but unfinished challenges still count. Earlier requests return
`{:error, {:resend_limited, retry_after_seconds}}`, without changing quotas or
challenges; an existing valid code remains usable. At exactly 60 seconds, one
concurrent caller can replace it and the others must wait again. Delivery failure
invalidates its challenge and permits immediate retry, subject to send budgets.

Engine reservations use the same current typed config snapshot already resolved for
the issuance operation. Channels operations read only a local typed snapshot from
`PeopleAuthRateLimiter.Config`; they never query
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
Malformed IPs return `:invalid_ip`, and missing rate infrastructure returns
`:rate_limiter_unavailable`. Runtime limit changes use
current counts; window changes select another scale-specific bucket and do not
rewrite older buckets. Reverting a window can revisit its still-live bucket.

`retry_ms` is the native remaining fixed-window duration. Expiry restores budget;
there is no independent cooldown control or timer. Windows align to wall-clock
boundaries and permit boundary bursts. Counters are **eventually consistent**, not
an exact cluster-wide quota: simultaneous requests can overshoot, new/restarted
nodes begin empty, and partitions lose increments with no replay/state transfer.
Delayed hits are applied in the receiving node's current window. Clock differences
can change bucket attribution. No hard global overshoot bound is promised.

### Public People authentication (PR4)

Channels serves `GET /people/login`, `POST /people/challenge`, CSRF-protected
`POST /people/session` (verify) and `DELETE /people/session` (logout).
`GET /people/profile` is the protected self-service profile described above, with
Profile navigation and logout. People LiveViews have independent
live sessions from BO. `PersonAuth` protects HTTP and `People.AuthHook` checks
current identity, active status, access_profile and expiry on mount/reconnect and
every event. No periodic polling or idle-page revocation broadcast is required.

Anonymous requests for recognized protected People pages retain their canonical
application-relative path in the existing signed session. Successful OTP verification
consumes that continuation; direct login and invalid state fall back to
`/people/profile`, and logout clears pending state. The allowlist covers only People
page routes (including a canonical conversation UUID), never login/session endpoints,
resource downloads, query strings, fragments or external URLs. Redirect construction
retains Phoenix's configured deployment path prefix. Continuation changes navigation
only: each destination's current authentication and authorization checks remain
authoritative, and callers link directly to the protected page rather than constructing
authentication URLs.

`Zaq.Channels.PeopleAuth.request_challenge/2` performs its local precheck before
**one** confidential Engine request. `PeopleAuthGateway.request_challenge/3`
uses read-only `People.match_person/1` for profile/email-channel identity, then
quota-backed issuance, then `Jido.Exec.run/3` with `Zaq.Agent.Tools.People.NotifyPerson`.
The action dispatches confidential `:notify_person` to Engine, which forwards
confidentiality to the existing `Notifications.notify_person/3` Channels delivery. Delivery uses the
existing weighted preferred/fallback channel routing and a fixed subject. The
Markdown message places `**XXXX-XXXX**` on its own paragraph, followed by
"Do not share this code." and the final italic instruction
`*Input this code in the current Sign-in page*`. Existing channel formatting
renders Markdown for chat and strong/emphasis in HTML email; no auth-specific
adapter formatting is used. No agent runtime, LLM or workflow runs.
Only final `:sent` with `notified: true` is success; action message/content and
instructions never leave the private gateway. Unknown/ineligible outcomes are tagged internally
`:failed_identification`; only that outcome spends Channels' failure budget.
Public errors disclose no channel details. Showing OTP entry only after real
delivery intentionally permits account enumeration in V1; no decoys are issued.

Request and resend share public stage messages: unknown, inactive and missing
profile access all say "We couldn't start the authentication process for this
address." The existing `:delivery_failed` outcome says "We couldn't send your
verification code. Please try again later." Issuance/configuration/limiter and
other unavailable outcomes retain "Unable to send a sign-in code. Please try
again later." No identity, permission or transport reason is included. Failed
requests retain any pending session descriptor; OTP verification errors remain
separate.

Failed/raised/exited delivery invalidates only that request's challenge, using
literal-owner Person-before-challenge locks. Remote I/O holds no database lock.
Successful sends recheck current eligibility, expiry and supersession before
returning. Failure of A cannot invalidate later B. Process/node death or database
unavailability can prevent cleanup; expiry and supersession remain authoritative.

Confidential action failures emit safe structured diagnostics before Jido error
logging: delivery/execution phase, exception module (or `:unknown`), event trace id,
and, for raised exceptions, source module/function/arity without arguments.
The gateway logs validation/execution/delivery phase and challenge id. Neither
boundary logs raw results, exception messages, codes, bearer tokens or Person
details. Confidential failures reach Jido as non-retryable structured errors;
ordinary workflow error strings remain compatible. V1's existing notification
database payload retention is unchanged.

Email, resend and verification use conventional POST/redirect forms; LiveView is
presentational, so there are no outstanding asynchronous UI result generations.
Concurrent HTTP requests still consume normal backend budgets and supersession:
a late cookie response can show an old descriptor, whose code is rejected; resend
recovers. Buttons disable during submission to reduce accidental duplicates.
Wrong-code redirects retain the opaque challenge, both deadlines and email in the
signed cookie session, never the code. Code input and resend share one row;
Sign in sits below. Verification and resend have separate CSRF-protected HTTP
forms, associated explicitly without nesting. Resend displays `Resend in 00:45`
until its fixed deadline, then `Resend code`. Reload preserves that deadline;
new issuance resets it. Submitting keeps controls disabled across timer ticks.
Legacy descriptors without a resend deadline show an enabled resend button;
the server still enforces the same rule. A denied resend retains the current
descriptor and displays a generic wait message; an initial email denial stays on
the email stage with the generic unavailable message. OTP expiry does not change
the resend deadline or disable code input; backend verification is authoritative.

The session bearer is stored in existing Plug.Session under
`person_session_token`. It never enters URLs, JS, DOM or LiveView assigns. LiveView
receives the cookie through connect_info; cookie data is not copied into explicit
signed DOM live-session payloads. Phoenix filters password/secret/token/code
parameters; the unfiltered stock LiveView mount-session dump is suppressed at
compile time (see system-config logging guidance). Cookie transport is signed,
HttpOnly, SameSite=Lax, Secure in production, with the original browser-session
lifetime and no explicit Max-Age/Expires; the database enforces
the configured seven-day People session lifetime. Cookie renewal preserves BO
`user_id`; BO logout/invalid-user cleanup remove only `user_id`. Person logout
revokes its bearer and removes only Person keys. If server revocation cannot be
confirmed, it still clears the local credential and reports the limitation.

**Trusted IP V1:** only the direct `conn.remote_ip` is used. Auth mutations are
HTTP POSTs, so no LiveView peer-data IP path is needed. Forwarded client-IP headers
are ignored; there is no configurable proxy trust policy. A reverse proxy therefore
shares its peer-IP budget among its users. Hammer's native remaining-window
retry time varies; the public UI deliberately says to retry later rather than
promising a fixed cooldown. There is no broad ingress ceiling.
