# Resource policies

## Foundation status

This increment adds internal persistence, identity and policy-authorization
primitives. Confidentiality enforcement, routed policy-management Actions,
folder/team level resolution and BO policy editing are not active.
`Zaq.ResourcePolicies.ready?/0` returns `false` with no configuration
override. Follow Beadwork epic `zaq-w2e` for delivery, not this guide as a plan.

## Persistence and identity

`Zaq.Permissions.ResourcePolicy` stores one row per canonical resource coordinate.
Its independent nullable `classification_level` and `clearance_level` fields
describe the **target** resource. `nil` means inherit; explicit `0` remains an
override. Both values are nonnegative PostgreSQL integers. Resource coordinates
are immutable after insert, and `lock_version` fences concurrent edits.

The schema uses Ecto integer casting and number validation for `0..2_147_483_647`.
Integer form strings are accepted under Ecto's standard casting rules (fewer
than 32 bytes); floats, booleans, blanks and out-of-range values are rejected.
Blanks are not converted to nil: resetting an override requires explicit nil.

Policies do not add columns to `ResourcePermission`. That schema continues to
represent ordinary person/team content grants, potentially many per resource.
A policy row is identified by `{"resource_policy", policy.id}`; its
`resource_type`/`resource_id` identify the governed resource instead. Neither
grants on that row nor grants on its target authorize policy administration.

`Zaq.ResourcePolicies.ResourceRef` validates registered coordinates using existing
ACL type names, not the aliases in `resources.query`. Validation does not establish
that a target exists or authorize its use. The explicitly registered `default`
agent/provider identities are not a fallback for an invalid configured ID.

### Documents and folders belong to the data source

Document/file and folder policies reuse the **same target identities as source
Resource Permissions**, including files that have never been ingested. Mounted
Storage uses `%Zaq.Storage.StorageEntry{id: catalog_uuid}` / `{"storage_entry",
catalog_uuid}`. File/folder kind and verified ancestry remain Storage-owned; a
separate policy-only `source_file`/`source_folder` encoding is not used. Paths and
display names are not identity, and ancestry is not stored on the policy row.

`Zaq.Ingestion.Document` holds derived content. Its existing `{"document", row_id}`
ACL coordinate is unchanged, but it is **not** an independently editable
confidentiality target. Neither indexing, reingestion, nor an ingestion permission
grant creates a competing policy authority. No ingestion-row fallback or separate
legacy identity treatment is provided by this WIP feature.

The assigned PR-02 source resolver will bind ingestion-document references to the
verified originating source permission target. External providers must retain
provider + configuration + stable source record scoping through their owner's
verified mapping; an ingestion source string or unsigned metadata is not proof.
This foundation does not invent or implement those external mappings. Until that
resolver exists, ingestion-document references return `{:error, :unresolved_source}`.

Both fields will resolve independently: explicit **source-file** override > nearest
explicit ancestor-folder override > default. An unset classification may inherit
while clearance remains explicit, or vice versa. For genuine multiple-parent
sources, resolve the nearest explicit value per branch, then take the maximum;
an explicit file field wins. Ingestion rows and indexed chunks/extracts derive the
same effective source values; none has a separately editable override or authority
to weaken its source. Hierarchy resolution remains a subsequent increment.

## Internal lookup and defaults

`Zaq.ResourcePolicies.fetch/1` is an internal security-resolution primitive, not a
BO endpoint or an authorization grant. It distinguishes invalid coordinates from
a valid coordinate with no policy. Database failures propagate instead of becoming
an unset policy. Target existence remains the owning domain's responsibility.
This internal coordinate lookup is not a hierarchy resolver or an existence check:
a caller must establish verified source identity before using it for resolution.
An unresolved ingestion reference is an error, never an absent row/default policy.

`Zaq.System.get_confidentiality_defaults/0` reads the independent
`system.confidentiality.classification_level` and
`system.confidentiality.clearance_level` values in a single query. Absent values
initially resolve to zero; malformed persisted values return an error. This
read uses a required schemaless Ecto changeset with the same integer bounds;
unlike policy overrides, a persisted null default is invalid. This increment
adds no default-writing or activation API.

## Internal administration

Only BO Users administer policies through their current persisted Role
capabilities, documented in [BO auth](bo-auth.md). The `ResourcePolicies` domain
boundary delegates capability evaluation to shared `Accounts.BOAuthorization`:
`view_resource_policies` for `read/2`, `add_resource_policies` for `create/3`, and
`edit_resource_policies` for `update/4`, including reset. Authentication occurs
before protected policy/target lookup. An add-only role cannot overwrite or edit
an existing policy, and edit authority does not grant view authority.

People and Teams are **policy subjects**, not administrators. Their classification
and clearance levels govern runtime confidentiality; high clearance, content ACL
management and People's portal permissions cannot administer policies. A Person
needing administration receives separate BO access with an appropriate Role;
there is no User–Person linkage or BO principal in ResourcePermission. Role and
capability assignment remains super-admin-only through existing guarded Accounts
administration. There is no Person/team policy grant, creation/admin scope,
automatic creator grant, policy grant/revoke API or administrator bootstrap.

Internal `create/3` validates a native target's existence and atomically inserts
the policy without writing any ResourcePermission rows. A duplicate Add fails
rather than overwriting a policy. Source-target existence resolution is deferred to its
owning source-resolution increment; a source reference alone is not enough to
create a row. Even a valid Storage catalog UUID does not enable source mutation
in this foundation. Both source creation and edits return `:unresolved_source`
until owner verification is available. An ingestion row's existence cannot
substitute for that verification.

Internal `read/2` and versioned `update/4` recheck current BO operation authority.
Resetting an override to nil retains the policy; ordinary content ACLs are unchanged.
Unsupported ingestion-target rows cannot be read as valid policy or edited/reset
through these operations, even by a privileged BO user. Changeset validation also
rejects ingestion-row targets. Source writes still require owner verification;
schema coordinate validation alone does not grant permission to mutate a source.
There is no policy deletion or public policy administration endpoint in this
increment. Database errors propagate rather than being treated as defaults.

These are domain operations for trusted code, not deployment-readiness grants.
Subsequent external Engine Actions must enforce readiness **as well as** domain
authorization before exposing any policy mutation/default editor. Direct domain
tests do not activate the product.

## Subsequent enforcement boundaries

Routed BO administration and ResourceQuery policy-record disclosure will reuse
the same current BO role authorization, not Person/team policy ACLs. Internal
policy resolution for ordinary Person/portal content access remains separate and
does not require administrative BO authority. Clearance escape for the requesting
BO user is issued by `Events.TrustedContext.from_bo_actor/1`; it grants neither
policy administration nor content permission and must not bypass recipient channel,
agent, AI-provider or MCP clearance. These consumers are not implemented by the
foundation primitives above.

Record hydration will evaluate permissions before confidentiality and attach
trusted effective levels before disclosing content/handles. Existing bearer-handle
and source-specific redemption contracts remain owned by
[Materialization](materialization.md); policies do not put authorization grants in
handles. Runtime enforcement and fresh queued-ingestion hydration are subsequent
increments, not guarantees of this persistence-only change.
