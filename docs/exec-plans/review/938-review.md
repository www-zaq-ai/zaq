# PR-01 resource-policy foundation review

- PR: [#938 — feat(resource-policies): add inactive policy foundation and guarded BO role mutations](https://github.com/www-zaq-ai/zaq/pull/938)
- Branch: `feature/350-01-policy-foundation`
- Reviewed head: `7e30660882419128130cdd7a48deff706dbe4038`
- Parent issue: [#350](https://github.com/www-zaq-ai/zaq/issues/350)
- Delivery scope: PR-01 only, as specified by Beadwork `zaq-w2e.2`, `.3`, `.4`, `.38` and `.39` and the approved BO-only administration corrections. This PR does not complete #350.

## A. Inline review comments

No actionable code findings identified in this pass.

## B. General PR conversation comments

No additional code findings. The remaining release gates are tracked separately; this review is not a merge authorization or a GitHub approval. All GitHub Actions checks passed, but the separate `coverage/coveralls` commit status is failing on the reviewed commit.

## C. Final recap

### Verdict

**Approve the reviewed implementation for the PR-01 scope.** Coverage, final validation, human approval and authorized landing remain separate gates.

### Assessment

The implementation preserves the intended inactive boundary: `ready?/0` is hard false, source-policy writes require the deferred owner-verification work, and no policy editor or routed policy-management operation is activated. Independent nullable levels preserve explicit zero and explicit nil, including the string/atom-key normalization correction in the reviewed head. The migration enforces uniqueness and nonnegative values and refuses a destructive rollback of populated policy data.

BO policy capabilities reload persisted User/Role authority. Person/team content grants do not confer administrative rights. Clearance-context issuance remains separate from administration and content permission. Account permission checks stay in `Administration`; the existing `Accounts.update_user/2` performs row locking, stale-role-snapshot rejection and persistence. The Engine boundary retains confidential dispatch, server-derived actor context and existing welcome delivery without a separate Action wrapper.

### Findings summary

- High: 0
- Medium: 0
- Low: 0
- Inline comments: 0
- General code comments: 0

### Review coverage

- Read #350's description and both comments. No directly linked additional issue requires recursive inspection. Used the subsequent user-approved delivery and BO-only corrections rather than treating the parent issue's older tag proposal as the entire PR-01 contract.
- Inspected the persistence, reference, schema, defaults, account-authorization, account-update, Engine dispatch, trusted-context, BO mutation/form and TLS-fixture changes, their owner documentation, migration, and corresponding regressions. Checked related `BOActor`, `User.changeset/2`, existing welcome notification delivery and the LiveView async-wait implementation.
- Checked authorization-before-disclosure, capability separation/revocation, native/source identity boundaries, nil/zero preservation, optimistic policy locking, stale account-role snapshots, database constraints/rollback, error rendering and reuse of existing dispatch/domain operations.
- No new UI slice or independently composable operation warrants an additional component or Action. Existing form, notification and Accounts implementations remain authoritative.
- Verified the current PR's CI results: both database test jobs, format, Credo, documentation and Chromium/Firefox/WebKit E2E jobs succeeded. These results do not replace the required local coverage and final gate.
- The external Coveralls build `83032400` reports 97.258% overall coverage, a 0.009-percentage-point decrease, and 94.886% diff coverage (167 of 176 relevant lines covered). An authorized push and fresh CI result are needed to update that commit status; local coverage alone does not clear it.
- Current blocker-focused local run: 210 passing checks, including six properties, at seed `80378`, normal `max_cases: 16`. This includes the upstream grouped People-permission fixtures, portal-consent tests and TLS regressions. A scoped pass is not proof that the prior full-suite portal timeout is fixed.
- The user declined changing the portal async bound. Its existing 100 ms wait and assertions remain unchanged. The final local gate must determine whether the historical timeout recurs on this head.
- Fresh local `mix coveralls.json` succeeded within the required 600,000 ms limit: seed `530304`, `max_cases: 16`, 12,273 passing checks (48 doctests, 360 properties, 11,865 tests), one existing skipped test and 167 exclusions. Overall coverage was 97.2%. The historical portal and deadlock failures did not recur in this run; this is not a root-cause fix claim.
- `mix coverup` identified missing branches in `ResourcePolicies`, `Accounts.Administration` and the account `FormFlow` helper; additive test plans are tracked under `zaq-w2e.43.1`–`.3`.
- The eight additive tests now pass: 18 focused tests in the three edited/added test files, with all original assertions and fixtures unchanged. `mix q` and `git diff --check` also pass. No production source changed in this coverage follow-up.
- The required targeted `mix test ... --cover` run passed. Its limited selection reports 100% for `Accounts.Administration`, 93.7% for `ResourcePolicies` and 20% for `FormFlow`; it does not rerun the other tests that covered these modules in the initial full report. A separate targeted JSON capture confirms positive hits on every originally missed reachable line. Combining those measured hits with the fresh full baseline, after checking identical production source, gives 100% for each of these three modules. This is combined measured evidence, not a second full-suite coverage run. The original full report and the targeted JSON capture are preserved separately in the session's temporary directory.
- Coverage exception: `RoleFormLive` is 94%, with only line 35 uncovered. That pre-existing line is the body of an anonymous `new_entity` callback supplied by the edit action. `FormFlow.assign_entity_form/4` invokes that callback only for the new action, whose separate callback is at line 24. Both routes already have tests; no public route can execute line 35. Do not alter production code or manufacture a private callback test solely for this percentage. Evidence is tracked in `zaq-w2e.43.4`.
- Final local `mix precommit` exited 2: seed `948892`, normal `max_cases: 16`, 12,280 of 12,281 checks passed (48 doctests, 360 properties, 11,872 of 11,873 tests). The only failure was the unchanged `OrphanedRunRecoveryTest` cancellation case at line 265, with a Sandbox connection disappearing during `Workflows.cancel_run/2`. This matches the failure area already tracked in `zaq-91y`; no root cause or baseline attribution is established by this run. The whole unchanged workflow file passed all 11 tests in isolation with the same seed. That isolated pass is not a fix or a final-gate waiver. The portal timeout and model/People deadlocks did not recur in either fresh full run.
- An independent Copilot review was requested. No GitHub review has been returned at the time of this report. The failing final local gate, publication of the additive tests, refreshed remote coverage status and human approval remain outstanding. No workflow code, existing assertions, concurrency settings or portal wait bounds were changed.

### Token usage

Runtime token accounting is not exposed for this review. Estimated review-specific input: 25,000 tokens; output: 1,000 tokens; total: 26,000 tokens. These are estimates, not measured session usage.
