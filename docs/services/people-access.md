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

| API atom / storage string | Matrix label |
| --- | --- |
| `access_profile` | Access profile |
| `access_message_history` | Access message history |
| `share_conversations` | Share conversations |

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
grants do not authorize BO administrators or change login/session behavior.
They are capability APIs and configuration only; this slice adds no public profile,
message-history, conversation-sharing, or portal routes.
