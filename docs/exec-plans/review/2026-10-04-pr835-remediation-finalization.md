# PR #835 remediation re-review

## Verdict

Technical re-review: approve the implemented remediation scope for coverage and
final validation. This is not final human approval, feature completion, publishing
authorization, or approval of a future Repo-free Channels deployment.

Reviewed against working-tree changes on
`f634e990cc91f2974c7fda54ace5bb3958a56d63`, not the unchanged published PR head.
No new confirmed high/medium/low code findings in this scoped pass.
Inline comments: 0. General code findings: 0.

## Context and finding coverage

Read PR #835 metadata and issue #768 description/all four comments, including
the historical #799/#800 foundation stack and superseded follow-ups. PR #835 has
no published review threads or conversation comments at review time. The saved
seven-finding remediation plan and current handoff provide the remediation scope;
later user decisions supersede its old Channels-owned email/archive proposals.

- F1: replicated replay compares requested/persisted placement scopes before
  adopting targets; source conflicts cannot silently move replicas. Person-merge
  identity, grants, canonical IDs and transcript cursor contracts are preserved.
- F2: source scope uses the shared opaque nil-or-1–255-byte invariant; guarded
  source-account storage widening preserves encoded identities and rejects unsafe
  rollback narrowing.
- F3: BO email snapshots/save/default selection are confidential Engine operations;
  the existing Zoi-backed save Action owns authoritative persistence. Channels
  consumes the exact supplied runtime configuration, not a provider-only reload.
- F4/F5: provider registration selects provider-local normalization and room-query
  implementations. Engine derives history kind/title/capture policy; generic
  transport routing does not choose a history strategy.
- F6: bounded history list projection batches participants, identities, roots and
  ratings; provider fallback remains detail-only. SQL-budget regression exists.
- F7: Engine validates descriptor/revision, orders watches/teardown, locks and
  persists archival, then reconciles runtime/cleanup. Channels leaf operations
  take supplied maps without current-actor or configuration Repo lookup.
- Archive follow-up: runtime reconciliation invokes the configured bridge's
  `stop_runtime/1`, not a fabricated enabled-to-disabled update. Real Jido webhook
  regressions prove initial delete-once, no delete on retry, pending stop failure,
  sibling runtime isolation and unchanged ordinary-disable behavior.

## Boundaries and reuse

Reviewed source/replay changes, Engine email/lifecycle/Action contracts, neutral
ingress/delivery consumers, provider normalization/query delegation and batched
projection, including their API callers and regression tests. Schema-reference
changes preserve the same table/FKs; pure settings access has a shared neutral home.
Existing archive/save/membership Actions and canonical capture implementations
remain authoritative; no parallel operation or new automatic agent-tool exposure.
Runtime stop reuses the existing callback and idempotent missing-runtime handling.

Legacy Channels bootstrap, provider-only synchronization, delivery/attachment
database callers are deferred by approved scope. The schema namespace move does
not isolate those callers or establish a Repo-free Channels node.

## Validation and remaining gates

Latest affected archive run: 533 tests / 2 properties passed; `mix q` passed with
one scheduler. Earlier wider passes remain historical evidence for their trees,
not substitutes for final validation. Existing browser runs had readiness/dialog
timeouts that passed isolated retries; fresh browser validation remains required.

Coverage generation and the final `mix precommit` gate are pending. Any outstanding
human UX approval/new-feature E2E gate remains separate from these regression runs.
No code was changed for this re-review; no GitHub review was posted.

Publication follow-up: the user authorized committing/pushing to PR #835 to use
GitHub CI under local resource contention. Latest browser retry: 71 passed and
one People-access LiveView-readiness timeout; isolated retry timed out. Fresh
coverage failed database checkout during startup, then the four-scheduler retry
timed out at 600 seconds with a partial ingestion sandbox-checkout failure.
No successful fresh report or `mix coverup` result exists. Final precommit is
pending; publication does not imply merge approval or completed validation.

## Review accounting

Severity counts: high 0, medium 0, low 0. Token usage: runtime metrics unavailable;
estimated review-only input ~28,000 tokens and output ~1,000 tokens. These are
estimates, not session billing measurements.
