# Goal

Implement PR-01 of GitHub #350: the inactive resource-policy foundation, BO role
authorization, and explicit policy permissions. Deliver six feature PRs followed
by separately gated obsolete-column cleanup, not one monolithic PR. Beadwork
`zaq-w2e` owns the plan/progress; this is a checkout handoff snapshot only.

# Current State

- Branch `feature/350-01-policy-foundation`, based on `main` at `a2a1a1e9e`.
  Worktree is dirty with tracked modifications and new untracked source/tests.
  No commits, pushes, GitHub PRs, merges, or task closures were performed.
- Original checkout is untouched. Session directory is the isolated OpenCode
  worktree, not the original repository. No stashes were created or consumed;
  existing repository stashes belong to other work and must remain untouched.
- Installed Elixir 1.20.4 and OTP 29.0.2 were selected through per-command
  `ASDF_ELIXIR_VERSION`/`ASDF_ERLANG_VERSION`. Default worktree shims otherwise
  select Elixir 1.19.5, which is wrong for this baseline. The original checkout's
  local toolchain selects OTP 28.5.0.2; no toolchain file was added here.
- `mix setup` succeeded: dependencies, isolated branch database, migrations,
  assets, and fetched Python scripts. Source `config/dev.secret.exs` was copied
  locally and is ignored. Source `.claude/settings.local.json` was absent, so no
  personal host settings were copied.
- Last application edit was before the green `mix q` and expanded isolated run:
  **477 passed: 25 properties and 452 tests**, seed 292087. That run included
  Accounts, Permissions, policies, Events, the new Engine Action, and BO accounts.
- `mix precommit` **failed**, exit 2: **11675/11685 passed**, with 48 doctests,
  285 properties, 11342/11352 tests, one skipped and 155 excluded. It was not a
  timeout. Five failures were Python/JRE prerequisites and five were widget TLS
  certificate generation, not observed feature assertions.
- Reusing the original checkout's existing Python environment via `.venv` symlink
  fixed the conversion failures without installing packages. Subsequent isolated
  conversion/RecordSource/widget run: **84/89 passed**, seed 48115, with only the
  five TLS failures remaining. The symlink is **untracked, not ignored**; never
  include it in a commit. Earlier progress comments describing it as ignored were
  inaccurate; treat this verified state as authoritative.
- TLS fails at `test/support/widget_tls_fixtures.ex` during one of its three
  OpenSSL commands. A standalone first CA-generation command succeeds under the
  same Mix environment. Exact failing command/stderr is not yet established.
  These tests are outside edited feature paths, but failure on untouched baseline
  has not been independently established: do not label it proven pre-existing.
- Validation blocker: **`zaq-w2e.40`**. Final gate is red; do not request final
  human approval or claim ready-to-land. Independent review and post-review
  coverage phase are also outstanding.
- `ResourcePolicies.ready?/0` remains hard false; no routed policy-management
  API, model tool, default editor, or confidentiality UI was activated.

# Active files

Paths are relative to this worktree. **New/untracked files are not included by
plain `git diff` and must not be lost.** This handoff is itself new/untracked.

| File | State | What it is |
| --- | --- | --- |
| `docs/README.md` | Modified | Index link to policy foundation guide. |
| `docs/services/bo-auth.md` | Modified | Guarded role mutations and named role capabilities. |
| `docs/services/resource-policies.md` | New/untracked | Implemented foundation contracts and explicitly deferred enforcement. |
| `lib/zaq/system.ex` | Modified | Reads independent strict confidentiality defaults in one query. |
| `lib/zaq/permissions/resource_policy.ex` | New/untracked | Separate target policy, nullable levels, immutable coordinates, versioned edits. |
| `lib/zaq/resource_policies.ex` | New/untracked | Authorized internal read/create/update/scope grants; no routed activation. |
| `lib/zaq/resource_policies/authorization.ex` | New/untracked | Current BO role versus current Person/team policy ACL decisions. |
| `lib/zaq/resource_policies/level.ex` | New/untracked | Strict nonnegative PostgreSQL integer parsing. |
| `lib/zaq/resource_policies/resource_ref.ex` | New/untracked | Canonical allowlisted types, native/source identities, creation scopes. |
| `priv/repo/migrations/20261023000000_create_resource_policies.exs` | New/untracked | Policy table/constraints; rollback refuses nonempty policy data. |
| `lib/zaq/accounts/bo_authorization.ex` | New/untracked | Current persisted BO role authority and canonical narrow caller context. |
| `lib/zaq/accounts/administration.ex` | New/untracked | Guarded role CRUD and user role assignment; unchanged-role profile edits retained. |
| `lib/zaq/engine/actions/account_administration.ex` | New/untracked | Validated, non-agent-tool mutation Action and post-create welcome side effect. |
| `lib/zaq/engine/api.ex` | Modified | Confidential account administration event handler through Jido.Exec. |
| `lib/zaq/events/trusted_context.ex` | Modified | Separate trusted `skip_actor_clearance` transport, never actor/request claims. |
| `lib/zaq_web/live/bo/accounts/mutations.ex` | New/untracked | Explicit NodeRouter Engine dispatch with session User identity. |
| `lib/zaq_web/live/bo/accounts/form_flow.ex` | Modified | Safe unauthorized/non-changeset mutation errors. |
| `lib/zaq_web/live/bo/accounts/role_form_live.ex` | Modified | Role writes use guarded Engine Action. |
| `lib/zaq_web/live/bo/accounts/roles_live.ex` | Modified | Role deletion uses guarded Engine Action. |
| `lib/zaq_web/live/bo/accounts/user_form_live.ex` | Modified | Role-bearing creation/profile update routed; password behavior preserved. |
| `test/zaq/permissions/resource_policy_test.exs` | New/untracked | Nullable levels, constraints, duplicate targets, locks, properties. |
| `test/zaq/permissions/resource_policy_migration_test.exs` | New/untracked | Migration refuses to discard persisted policies. |
| `test/zaq/resource_policies/resource_ref_test.exs` | New/untracked | Canonical IDs, source tuple isolation/roundtrip properties. |
| `test/zaq/resource_policies/foundation_test.exs` | New/untracked | Inactive readiness and no fallback after repository failure. |
| `test/zaq/resource_policies/authorization_test.exs` | New/untracked | Explicit record/scope grants, BO distinction, current membership. |
| `test/zaq/resource_policies/persistence_test.exs` | New/untracked | Atomic creation, grants, duplicates, reset/conflict, bootstrap scope. |
| `test/zaq/system/confidentiality_defaults_test.exs` | New/untracked | Absent defaults zero, malformed values error. |
| `test/zaq/accounts/bo_authorization_test.exs` | New/untracked | Current BO role capability matrix, canonical context, no injected bypass. |
| `test/zaq/accounts/administration_test.exs` | New/untracked | Privileged mutations and unchanged-role profile behavior. |
| `test/zaq/engine/actions/account_administration_test.exs` | New/untracked | Validated Action, trusted actor, confidential event requirement. |
| `test/zaq/events/actor_clearance_context_test.exs` | New/untracked | Separate literal trusted capability, no actor/request inference. |
| `test/zaq_web/live/bo/accounts/role_authorization_test.exs` | New/untracked | Formerly exploitable role mutation/promotion and live-role revocation. |
| `test/zaq_web/live/bo/accounts/role_form_live_test.exs` | Modified | User-approved administrative fixture elevation, assertions preserved. |
| `test/zaq_web/live/bo/accounts/roles_live_test.exs` | Modified | User-approved administrative fixture elevation, assertions preserved. |
| `test/zaq_web/live/bo/accounts/user_form_live_test.exs` | Modified | Only user-creation admin cases tagged for privileged fixture; ordinary password/profile cases unchanged. |
| `test/zaq_web/live/bo/accounts/users_live_test.exs` | Modified | Only account-creation case uses privileged fixture. |
| `.venv` | New/untracked local symlink | Existing Python environment reuse; local-only, not product code, do not commit. |

# Changes Made

1. Policy storage separates resource-wide classification/clearance from grants.
   Zero and unset stay distinct. Canonical identities use existing ACL type names,
   while source coordinates encode provider/config/ID without delimiter ambiguity.
   The registry does not authenticate source provenance or supply hierarchy.
2. Internal policy operations check record/scope authority, insert creator grants
   transactionally, avoid duplicate-Add overwrite, and require versions on edits.
   Native target existence is checked. Source-catalog resolution remains a later
   PR and unsupported source lookup does not become default policy. No public
   policy Action/tool/UI exists in this increment; later endpoints must enforce
   readiness as well as domain authorization.
3. User chose **existing BO roles**, explicitly rejecting User-to-Person linkage
   and a new BO User ResourcePermission principal. Non-BO Person/team grants
   remain explicit. BO authority reloads current User/Role, never client role data.
   Super-admin has policy capabilities; other roles require named metadata grants.
4. Caller-clearance escape is independent of content permission and recipient
   safety. Canonical BO context strips legacy actor-supplied bypass claims;
   transport supports only the literal trusted flag. Enforcement callers are
   subsequent increments, not active just because the struct has the field.
5. User explicitly approved super-admin-only role create/edit/delete and User role
   assignment after the unguarded legacy forms were demonstrated. They separately
   approved administrative fixture upgrades while retaining existing success
   assertions and ordinary password/profile fixtures. New denial tests failed
   against old code, then passed after guarded Engine routing.
6. User decided confidentiality checks mirror data-source permission checks at
   authorized Record hydration, not a new generic handle-redemption check. Preserve
   source-specific existing transcript/IMAP checks. Ingestion's stored source
   Records actually include handles, so fresh queued/retried hydration remains
   tracked for a later PR. No handle security contract was changed here.
7. Beadwork P01/P02/P03 and supplemental guard scopes remain in progress/unclosed
   pending authorized landing. `.38` and `.39` are explicitly PR-01, not extra PRs.
   The overbroad G0 edge to additive P03 was removed with recorded rationale;
   G0 remains open for actual later legacy behavior changes. No legacy feature
   test changes outside the explicit admin-fixture approval were made.

# Failed attempts

- Initial shims selected Elixir 1.19.5 in the new worktree. Used installed 1.20.4
  with per-command environment rather than modifying user-level toolchain config.
- Expected TDD red runs failed on absent new schema/authorization methods. A new
  LiveView test initially missed fixture imports; fixed before establishing its
  real four-denial regression failures.
- New Action tests initially assumed Jido returns raw domain errors. It wraps
  Action failures, so expected domain denials now travel in a validated `result`
  output and Engine returns the domain result. No existing assertions weakened.
- An initial alias pointed at `Zaq.Utils.Map`, which lacks `fetch/2`; corrected to
  existing `Zaq.MapUtils` after the isolated failure.
- Guarded profile validation initially returned a changeset with no `:update`
  action, hiding errors. Fixed the production changeset action; the unchanged
  existing validation test now passes.
- `mix q` found nesting, alias ordering and single-clause-with warnings in new
  code. Fixed locally; final `mix q` passed.
- Native `bw start` for P03 refused because its same-PR predecessors remain
  unclosed without commit authorization. Status was explicitly updated to reflect
  actual grouped-branch implementation; comments make clear this is not false
  predecessor landing/completion.
- Initial final gate failed ten tests. Python/JRE environment issues were fixed
  through existing local dependency reuse; five TLS fixture failures remain in
  isolation. First standalone OpenSSL step works; do not repeat package installs,
  skip TLS checks, or claim root cause has been established.

# Next step

1. **Ready:** Resume validation blocker `zaq-w2e.40`: identify the exact failing
   existing TLS fixture subprocess and its stderr. Preserve assertions and avoid
   unrelated application fixes. Ask the user before broadening scope or modifying
   existing test behavior. This is the unresolved final-validation blocker.
2. **Ready after environment repair:** Rerun the four affected suites, then a fresh
   `mix precommit` through Context Mode with a 900000 ms timeout. Do not substitute
   the scoped 477 green cases for the final gate.
3. **Ready:** Review the complete dirty diff, including all untracked code and the
   guarded role mutation seam. Independent review/coverage phase is not complete;
   follow the repository validation lifecycle before final human approval.
4. **Blocked on user:** Commit/push/open PR/merge require authorization. None was
   inferred from “let's go.” Do not close implementation tickets as landed yet.
5. **Optional:** If desired, move this snapshot's long-form details into a ticket
   attachment before landing; Beadwork remains authoritative. Keep the local
   `.venv` symlink out of commits and do not modify its shared packages.

Do not start PR-02 in this worktree, activate policy editing, link BO Users to
People, add generic redemption-time policy checks, broaden clearance bypass to
destinations, weaken legacy assertions, or disturb existing stashes. Sovereign
retirement, full hierarchy/runtime enforcement and new feature E2E remain in their
assigned later PRs; completed-feature E2E still requires explicit UX approval.
