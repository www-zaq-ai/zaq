# Configured-only Agent cleanup — local review

- Proposed PR title: `refactor(agent)!: remove built-in Default Agent and legacy Pipeline`
- Cleanup PR: not published yet; no Git commit or push at this review checkpoint.
- Branch: `zaq-nnx/remove-default-agent`
- Stacking base: `zaq-o9i/composable-knowledge-search`, [PR #912](https://github.com/www-zaq-ai/zaq/pull/912), baseline `578d9db41`.
- Primary issue: Beadwork `zaq-nnx`, implementation/approval children `.1`–`.10`; review gate `.11`.
- Related context: `zaq-jrg.27`, `zaq-w2e` and `.18`/`.19`/`.20`.
- Reviewed: 2026-11-02. This is a local implementation review, not final landing approval or a GitHub reviewer decision.
- Local review acceptance: recorded in Beadwork `zaq-nnx.11`; Julien approved proceeding to coverage.

## A — Inline review comments

No unresolved inline findings.

### Resolved during acceptance/self-review

1. **Medium — terminate BO no-answer activity without inventing an answer**
   - Location: `lib/zaq/channels/web_bridge.ex:496–537`.
   - Evidence: a real Chromium journey submitted an exhausted route and reproduced a permanently disabled composer. No Agent was selected, so its normal completion event could never arrive.
   - Resolution: reuse the existing routing-disposition receipt and correlated status delivery to publish idle for BO no-answer completion. Do not construct an assistant result, bypass Engine, or change widget acknowledgement semantics.
   - Verification: new LiveView regression and Chromium/Firefox/WebKit journeys assert enabled composer, unchanged assistant count, and no model calls after exhausted/deleted selections.

2. **Medium — preserve optional delivery on BO ingress**
   - Location: `lib/zaq/channels/web_bridge.ex:524`.
   - Evidence: `Context.new/2` explicitly permits `delivery: nil`. The first completion implementation attempted a broadcast anyway, reproducing `{:error, :dispatch_error}` for a valid unbound caller.
   - Resolution: acknowledge no-answer directly when there is no delivery descriptor; only bound consumers receive status delivery.
   - Verification: an additive real-flow regression reproduces the failure before the guard and passes afterward. Existing ingress expectations are unchanged.

## B — General PR conversation comments

No unresolved general code findings. The following are explicit release/validation conditions, not claims that those gates are complete:

- **Deployment compatibility:** old/new nodes must not admit implicit built-in work concurrently. Drain in-flight synthetic answering, coordinate roles, and audit installed external add-ons for the five retired Pipeline hook events. External deployed packages were not available for verification. See [deployment guidance](../../operations/deployment.md#upgrading-to-configured-only-agent-execution).
- **No speculative migration:** audited routing persistence has only configured-agent/None rules; absent rules mean inheritance. There is no proven separately stored built-in ID to rewrite. Keep blank/inherited rules and configured assignments intact.
- **Remaining gates:** coverage and final full-suite precommit pass, with the bounded human-approved coverage exception below. Final human approval and authorized commit/push/stacked PR publication remain outstanding. The unreproduced consent timeout is tracked separately in `zaq-s2y`, not claimed fixed. Do not mark the epic landed.

## C — Final recap

### Verdict

**Approve the local implementation and coverage-phase test additions**, with no unresolved code findings. Local review acceptance and the bounded coverage exception are recorded in Beadwork. This does not replace final human/PR approval or final validation gates.

### Assessment

The cleanup satisfies the configured-only direction without introducing a replacement default, parallel retrieval implementation, new production Action, or test-only runtime endpoint. Engine retains routing policy, configured runtimes retain lifecycle/authentication, and Channels owns the BO no-answer protocol completion. Shared search Actions, QueryFilters, Hooks infrastructure, credentials, context budgets, and the ingestion Python Pipeline remain.

Scoped Default/inherit and explicit None remain distinct. Exhausted inheritance ends at None; missing direct execution selection is safely finalized without starting a runtime. Compatibility action/option/result names and `answering.*` tool keys are intentionally retained. Historical prompt-template records are preserved rather than deleting potentially customized data.

The current configured-path limitation that `Executor.success_result/4` emits empty sources predates this cleanup; renderer fixture tests do not claim to fix runtime source collection. Real browser search tests independently prove persisted knowledge results are consumed before the final answer.

### Findings summary

- Unresolved: high **0**, medium **0**, low **0**.
- Active inline comments **0**; active general code comments **0**.
- Resolved medium findings **2**, recorded above with reproduction and regression evidence.

### Review coverage

- Scope inventory: **66 changed/new files before this report** — 26 production paths (including four module deletions), 31 test/support paths, nine documentation paths. No base-PR search implementation was rewritten.
- Production owners inspected: Agent API/Executor/RequestControl/active lookup, Engine routing/router, CommunicationBridge/email/Jido/WebBridge, Hooks catalogue, BO selectors and diagnostics. Remaining Factory/StreamEvents/Outgoing/PromptGuard/registry changes update removed-runtime references and examples.
- Test changes checked against Julien's explicit scope approval in `zaq-nnx.1`: synthetic no-ID/default success becomes safe refusal/None; exclusive module/probe/stage tests retire; configured authentication, admission, finalization, history, controls, search and renderer assertions remain or move to appropriate fixtures.
- Security/lifecycle overlap: `zaq-jrg.27` personal/global authentication coverage now uses an explicitly persisted configured agent; embedding/image/global storage contracts remain. `zaq-w2e.18`/`.19`/`.20` remain independent planned history/provider/session policy work, not features implemented or waived by this cleanup. No policy-admin authority or Person linkage was added.
- Reuse gate: existing Engine resolver/workflow-only branch, configured Executor and canonical request controls are reused; no tool auto-exposure. The small BO receipt adapter is local protocol completion, not a new domain operation. No duplicated production search/auth/permission implementation or new component/style abstraction was introduced.
- Performance: removed the implicit query-rewrite/orchestration path; no new per-message query loop, N+1, provider call, or unbounded allocation in the changed runtime path. The extra no-answer status is one existing-protocol PubSub publication for a bound BO consumer.
- Reference/shape audit: no remaining removed-module/override references in live code, tests, configuration or release paths; three supported hook events remain. Stable public names and unrelated ingestion Pipeline are intentional.

### Validation evidence

- Broad retained Agent/Hooks/add-on suite: **2046 passed**, 17 excluded.
- Authorized knowledge navigation/search integration including ParadeDB: **5 passed**.
- Final deletion-focused Agent/API/Executor/Hooks/add-on checks: **210 passed**.
- Selector/system configuration checks: **336 passed**; diagnostics/shared settings: **304 passed**.
- Latest BO/bridge/scoped-routing suite: **176 passed**, including two properties.
- Security/control/ingress/history integration recheck: **108 passed**, 21 excluded.
- New configured-routing browser journeys: **3 passed**, Chromium/Firefox/WebKit.
- New widget None-to-inheritance journey: **1 passed**; existing widget None acceptance also passed unchanged.
- Existing Global/navigation Playwright regression: **16 Chromium tests passed**.
- Latest `mix q`: passed; hook verification reports three supported events; whitespace/local-link target checks passed.
- Final uninstrumented `mix precommit --no-stale --seed 559415`: **11,747 checks passed** (48 doctests, 304 properties, 11,395 tests), one existing skipped test and 155 excluded by existing tags. The full test phase took 449.0 seconds; formatting, strict Credo and compile gates passed. The consent test and its wait are unchanged.
- Counts describe separate runs with overlapping coverage; they are not a combined unique-test total. The first final gate failure and investigation are preserved below. Existing warning/error logs are not represented as clean output or waived test failures.

### Coverage-phase re-review

The first fresh coverage attempt exited 2. A focused rerun independently reproduced
the hook-verifier success fixture still dispatching two retired events. The fixture
now uses supported embedding-reset/feedback events, and its duplicate-dispatch case
also uses a supported event to isolate uniqueness. Every assertion and scenario
intent is preserved; the parser's arbitrary-atom fixtures are untouched. This adds
one test path beyond the original review inventory and falls within the approved
hook-event migration. Its 11 isolated tests and `mix q` pass. A fresh initial report
is being generated after this repair; no failed/stale report is used for coverage
planning. See `zaq-nnx.12` for the authoritative gate outcome.

The next initial report reached 11,736/11,741 passing checks; its five failures
identified the absent documented Python environment (local virtualenv, conversion
extras and bundled JRE). Installing the existing pinned requirements in an ignored
Python 3.12 `.venv` repaired those prerequisites without changing application code
or assertions. All 61 checks in the affected conversion/source/dedup suites pass.
That attempt required a fresh initial coverage run; failed reports were not reused.

The repaired-environment run reached 11,740/11,741 passing checks. Its sole failure
was a PostgreSQL deadlock in unchanged OAuth gateway setup while deleting shared
People permission grants; that file's 11 isolated tests pass. This matches the
class of full-suite contention tracked in `zaq-e8q`, without proving the exact same
root cause. Coverage generation was blocked and `mix coverup` did not run against
the failed report. The next validation strategy required a decision; no
assertion or test exclusion has been changed to hide it.

After investigation, Julien explicitly approved resource-group scheduling for
eight shared-grant test modules (`zaq-e8q`, 2026-11-03). PostgreSQL logs establish
the table-wide grant-delete/upsert lock cycle. Each module remains `async: true`
with a private sandbox; only its shared-grant group is mutually exclusive.
Byte-level re-review confirms the eight files differ solely in that declaration,
without changing test bodies, fixtures, assertions or production code. Their 174
checks pass at seeds 0 and 136536; 22 real concurrency tests and `mix q` also pass.
The fresh initial report at the original failing seed 136536 now passes with
**11,741 checks** (48 doctests, 304 properties, 11,389 tests), one existing skipped
test and 155 excluded by the existing tags. Default module concurrency remains 16.
The normal `mix coverup` ran only after that success. All 21 surviving changed
production `.ex` files were checked against this cleanup's diff rather than the
stacked base PR; 19 reach at least 95%. The remaining planner/fixer scope is
Executor (94.4%) and AI diagnostics (65.9%), tracked in `zaq-nnx.12.1` and `.12.2`.
The changed HEEx template is validated by UI tests, not represented in this JSON.
No repeat full-suite numerical run is planned; final coverage checks target only
the edited test files, followed by the separate required `mix precommit` gate.

The planner/fixer pass added two Executor boundary scenarios and four diagnostics
LiveView/Python scenarios, without production changes or altered assertions.
The final targeted coverage run passes **119 checks** (six doctests, one property,
112 tests): Executor **95.0%** (288/303 relevant lines) and diagnostics **88.6%**
(39/44). The five remaining diagnostics lines cover fixed-interpreter failure/
exception and mount-time database-query rescues (68, 74, 105, 111, 117). A documented
human coverage exception was explicitly accepted by Julien on 2026-11-03 in
`zaq-nnx.12.2`. No production hook or disruptive shared-state fault was added merely
to raise the percentage; no failing test or final validation gate was waived.

Log review also attributes unowned Telemetry.Buffer flush noise to the bare
Executor unit test module: its 63 checks reproduce the logs independently, whereas
the integration/diagnostics-only 56-check run passes without them. This is not a
claim of clean logs or proof of the separate `zaq-mcw` stale-holder failure. The
new tests retain explicit actor and telemetry persistence assertions. The latest
`mix q` and whitespace check pass. Final precommit now passes as recorded above;
landing approval remains outstanding.

### Final-gate consent timeout investigation

The first final `mix precommit` at seed 559415 passed 11,746/11,747 checks. Its
sole failure was the unchanged consent transport-error test awaiting banner async
work with LiveView's default 100 ms bound. The failure preceded its onboarding
request and generic-error assertion. Both consent production and test files are
unchanged by this branch. Julien declined a proposed five-second wait, requesting
evidence for the delay; that proposal is withdrawn and no test change was made.

The seven consent tests pass at the original seed and in 31 repeated module runs.
Independent trace-session diagnostics under the BO/integration workload pass
1,947 checks: consent async work took at most 0.323 ms, portal mock calls 3.830 ms,
and mock ownership operations under 0.4 ms. These observations do not reproduce
or explain the original failure. No network, database, scheduler or mock-ownership
root cause is established. Do not treat an isolated pass as proof of a fix.

An earlier diagnostic mistakenly used the VM's shared legacy trace session and
conflicted with tests that install their own tracers, producing 29 failures. That
run is contaminated, not accepted validation or evidence of 29 application bugs.
The corrected probe uses a separate OTP trace session and lives only in the
approved temporary directory, outside the checkout. The plain, uninstrumented
final gate at the original seed now passes all 11,747 checks with no timeout or
assertion relaxed. This does not establish the original failure's cause or a fix.
Follow-up `zaq-s2y` retains the investigation and reproduction requirement. No
further consent behavior or test changes are proposed without new evidence.

### Token usage

Actual per-review runtime token metrics are unavailable. Rough estimate for this selected local review pass: 12,000 input tokens, 1,500 output tokens, 13,500 total; not a measure of the full implementation session.
