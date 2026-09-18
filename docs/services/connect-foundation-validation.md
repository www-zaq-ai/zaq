# Connect foundation `.9` hardening review record

Date: 2026-09-14. Tracking: `zaq-jrg.9`, in progress pending parent review.
This records implementation/validation evidence, not a replacement execution plan.
The uncommitted `.3`–`.8` foundation was retained. No commit, push, worktree change,
or issue closure was performed. No Agent consumer or UI was implemented.

## Latest far-end provider review — current status

Two additional medium findings were reproduced and fixed after the foundation-green
run below. Earlier tests that deleted `GOOGLE_CLIENT_SECRET` did not establish
authoritative absence at the dependency boundary; the revised tests deliberately set
a nonempty ambient secret and restore it after each serialized test module.

### Actual boundary correction

1. Canonical exchange and refresh reuse the **existing generic token HTTP functions
   in `Connect.OAuth`**, including the existing clock/config/encryption seams. A
   configured `token_url` retains its existing semantics.
2. When that URL is absent, a new **secret-free metadata action**,
   `:data_source_oauth_token_endpoint`, routes through NodeRouter → Channels.Api →
   DataSourceBridge → JidoConnectBridge. It returns only the token URL from the existing
   OAuth profile lookup. No client secret, code, token or verifier goes to this lookup.
3. Catalog fallback requires an explicit nonempty bound client secret and fails closed
   before token HTTP when it is absent. Configured generic public clients still omit
   nil secrets without consulting the environment. No provider list is hardcoded.
4. Jido's direct explicit exchange/refresh delegates reject with
   `:explicit_oauth_transport_required`, preventing accidental return to dependency
   helpers that substitute environment credentials or omit PKCE. Legacy delegates,
   including channel and ambient fallback, retain their behavior.

Application files changed in this latest pass:

- `lib/zaq/engine/connect/oauth.ex`
- `lib/zaq/channels/api.ex`
- `lib/zaq/channels/data_source_bridge.ex`
- `lib/zaq/channels/jido_connect_bridge.ex`

No dependency source/version, production environment variable, auth persistence
framework, parallel OAuth client or unrelated application code was changed. Provider
profile ownership stays in Channels; Connect owns the existing generic form encoding,
including the exact PKCE verifier and explicit client material.

### Regression evidence

Initial RED run: **10 tests, 4 failures**, seed **259295**, before application edits:

- Trusted Person Google fallback callback succeeded but its actual HTTP form had no
  `code_verifier`, despite the authorization URL containing an S256 challenge.
- A nil-secret canonical code exchange incorrectly succeeded by borrowing the
  nonempty ambient `GOOGLE_CLIENT_SECRET`.
- Canonical org and Person refresh likewise incorrectly succeeded with that secret.

`oauth_provider_boundary_test.exs` now exercises the full trusted Person
start → opaque callback → actual HTTP seam without custom token URL. It observes
the submitted form **outside** provider exception handling and verifies the S256 hash,
exact client ID/secret/redirect, token persistence and absence of channel/ambient
secret material. Additional cases cover configured public-client exchange **and
refresh**, direct explicit-delegate rejection, unavailable endpoint failure, and
positive legacy ambient fallback for **both** code exchange and refresh.
`refresh_bridge_test.exs` retains org/Person nil-secret and empty/read-scope cases
with the ambient secret now set, rather than removed. Old canonical HTTP tests were
pointed at the existing generic HTTP seam; legacy tests retain their provider seam.

### Latest checks — these supersede earlier counts

| Check | Result |
| --- | --- |
| New provider/refresh plus bridge regression files | **37 tests, 0 failures**, seed 523333 |
| Broad focused coverage, including legacy token-edge tests | **29 properties, 2043 tests, 0 failures**, seed 297937, 81.0 seconds |
| Isolated bridge coverage (both existing bridge suites + refresh + provider-boundary suites) | **196 tests, 0 failures**, seed 273349, 29.1 seconds |
| **Full `mix test --seed 812387`**, 900-second bound | **48 doctests, 114 properties, 9099 tests, 0 failures**, 1 existing skip, 83 standard exclusions; **623.7 seconds**, exit 0 |
| Fresh E2E after application changes: `npm test -- --project=journeys-chromium specs/system_config.spec.js specs/channels.spec.js` | Bootstrap/DB/assets completed; **56 passed**, 1.2 minutes, zero retries |
| `mix format`, `mix q`, `git diff --check` | Passed; no quality issues |

Whole-file coverage for this pass: OAuth **158/159 = 99.37%**; DataSourceBridge
**266/274 = 97.08%**; Channels.Api **206/229 = 89.96%**; isolated JidoConnectBridge
**916/1184 = 77.36%** (268 missed). The new metadata lookup and explicit-delegation
guards are exercised. The broad report still omits the main bridge; the isolated
measurement is used rather than treating omission as coverage. Existing whole-file
exceptions remain **`zaq-lmv`** and **`zaq-fja`**, pending explicit acceptance.

Latest artifacts: `cover/jrg9-provider/excoveralls.json`,
`cover/jrg9-provider-bridge/excoveralls.json`; logs in the approved temp directory:
`jrg9-provider-focused-coverage.log`, `jrg9-provider-bridge-coverage.log`,
`jrg9-provider-full-final.log`, `jrg9-provider-e2e.log`.

These two far-end fixes are implemented and regression-verified. `.9` remains
uncommitted/in progress for **independent parent far-end recheck and coverage-exception
acceptance**. Neither approval nor independent review is claimed here.

## Earlier foundation validation — historical evidence

**All eight reported full-suite failures are resolved in this delivery.** The six
deterministic failures were foundation-introduced compatibility failures from `.3`
(manual Oban testing) and `.7` (claimed-refresh contracts), not evidence of a clean
pre-foundation baseline. The earlier residual-patch comparison below only established
that the latest refresh-context correction had not introduced them.

### Completed repairs

- **Four ingestion tests:** narrowly wrap the triggering `IngestWorker.perform/1`
  or `Ingestion.retry_job/1` call in `Oban.Testing.with_testing_mode(:inline, ...)`.
  Keep every original chunk count/status/error assertion and processor expectation.
  Global Oban manual mode and transactional notification isolation remain intact.
- **Legacy token-edge tests:** replace runtime NodeRouter module recompilation with
  the existing HTTP/config seams. A complete valid provider response reaches actual
  post-HTTP encryption failure using an invalid per-call write key, while application
  reads retain a valid key. Assert the approved safe error, unchanged raw token
  ciphertext/status and no new event jobs. Missing access tokens also cannot rotate
  material or enqueue notifications.
- **Ciphertext-shaped provider regression:** two successive real refreshes return
  valid `enc:` ciphertext as provider plaintext. Verify fresh outer encryption at
  rest, literal token values after loading and the exact literal refresh token sent
  on the next HTTP request. The embedded other-owner secret is never substituted.
- **Onboarding test synchronization:** use an explicit bounded 5-second async-work
  deadline instead of incidental 100ms `render_async` / 1-second automatic-navigation
  assumptions. Await monitored async tasks for consent UI and the actual redirect
  message for navigation paths. No sleeps, retries, global timeout changes, sandbox
  mode changes or auth production changes. A message-controlled external-response
  test verifies that registration and consent stay pending until metadata is released.

The last repair pass edits only these six test files:

- `test/zaq/ingestion/ingest_worker_test.exs`
- `test/zaq/ingestion/ingestion_test.exs`
- `test/zaq/engine/connect_token_edge_cases_test.exs`
- `test/zaq_web/live/bo/system/change_password_live_test.exs`
- `test/zaq_web/live/bo/system/onboarding_scenarios_test.exs`
- `test/zaq_web/live/bo/system/onboarding_scenarios_integration_test.exs`

### Onboarding investigation evidence

The full suite was rerun with **the same seed 812387** after the six deterministic
repairs, before changing the onboarding waits. It completed in **566.2 seconds**:
48 doctests, 114 properties, 9092 tests, **one failure** — the same short-password
`render_async` timeout. The exact stack was LiveViewTest `render_async/2` line 1080,
then `Enum.each`, `render_async/2` line 1077 and the short-password assertion.
Temporary diagnostic output captured the LiveView waiting in `gen_server:loop/5`,
status `:waiting`, message queue length zero while the async result was outstanding.
Other captured processes were in Postgrex/DBConnection operations. This established
an overly short asynchronous test deadline, not an auth expiry or validation defect.

The earlier unreachable-portal failure did not recur in that diagnostic full run;
its test had been waiting for asynchronous fetch plus registration plus provisioning
under a one-second navigation budget. An attempted `render_async` before navigation
was rejected during validation because it races LiveView teardown. The retained fix
waits for the actual navigation message with the same bounded async-work deadline.
Shared canonical `ZAQ Router` / system-config unique keys were inspected, but no
specific DB lock or global config mutation was proven to cause the recorded failures.
The result is not labeled environment-only or a proven pre-foundation baseline.
All temporary process diagnostics were removed.

### Final verification

| Check | Result |
| --- | --- |
| All six affected test files, `mix test ... --seed 812387` | **141 tests, 0 failures, 1 existing skip**, 22.2 seconds |
| **Full repository `mix test --seed 812387`**, 900-second runner bound | **48 doctests, 114 properties, 9093 tests, 0 failures**, 1 existing skip, 83 standard exclusions; **724.0 seconds**, exit 0, no runner timeout |
| `mix format`, `mix q`, `git diff --check` | **Passed**; quality check reports no issues across 1224 source files / 15641 modules/functions |
| Relevant E2E | Prior **56 passing Chromium system-config/channels tests** remain applicable: this final pass changed no application, callback or UI code; no redundant E2E rerun |

The one existing skip is `IngestWorkerTest`'s **processes non-binary unresolved paths**
(`@tag :skip`, `ingest_worker_test.exs:326`); it was neither added nor hidden here.
The 83 standard exclusions remain the configured integration/ParadeDB/real-browser
tags. These are not reported as passes or new exclusions.

Additional logs, in the same approved temp directory listed below:

- `jrg9-foundation-six-green.log` — intermediate regression run, including the
  ciphertext-shaped test's initially incomplete provider expiry fixture
- `jrg9-full-onboarding-diagnostic.log` — same-seed full reproduction and stacks
- `jrg9-final-affected-tests.log` — all affected files green
- `jrg9-full-final.log` — final full repository green

`zaq-jf6` and `zaq-q1v` are implemented and verified in this delivery; `zaq-zih`
records the investigated synchronization correction and full-run evidence. Issues
remain unlanded/in progress under the no-commit/no-merge instruction. `.9` has no
remaining reported implementation or test failure; **independent parent residual
review and explicit user acceptance of the documented coverage exceptions remain**.
No independent review or exception approval is claimed by this implementation agent.
Application coverage figures below remain valid because the final pass changes tests
only; bridge/API whole-file exceptions are still `zaq-fja` and `zaq-lmv`.

## Refresh re-review follow-up — historical validation

Parent review confirmed the five original corrections, but found that provider
**refresh** had not received the explicit credential context. This follow-up changes
only `lib/zaq/engine/connect.ex`, `lib/zaq/channels/data_source_bridge.ex` and
`lib/zaq/channels/jido_connect_bridge.ex` in application code.

Canonical refresh derives `oauth_credentials: :explicit` from the persisted grant's
canonical resource kind; legacy org/user refresh remains `:legacy`. The existing
Channels event/bridge context carries it to Jido. Refresh validates explicit client
identity separately from authorize/exchange redirect validation: refresh requires no
callback URI. The provider receives only A's client settings/token/scopes and never
borrows B's channel secret. No new framework, provider configuration or URL rules.

New `test/zaq/engine/connect/refresh_bridge_test.exs` uses real Connect, NodeRouter,
Channels, DataSourceBridge, Jido and Google provider code; only HTTP is controlled.
The provider's process-global Req option and environment fallback are restored after
this serialized module. Seven tests cover:

- Canonical org **and Person** A with nil secret cannot borrow B's secret. Google
  rejects before HTTP; the old A token remains. Both tests returned incorrect success
  before the fix: 6 tests / 2 expected failures, seed **470245**.
- Canonical refresh with empty/read scopes succeeds with A's own secret and no
  redirect URI, preserving A's refresh token and scopes.
- Missing/blank explicit client ID rejects rather than falling back to B.
- Legacy org/user refresh still uses channel B fallback when A has no secret.

### Checks before the final foundation repairs

| Check | Result |
| --- | --- |
| Original focused suite, with new tests, via `mix coveralls.json --output-dir cover/jrg9-refresh` and the paths below | **29 properties, 2026 tests, 0 failures**, seed 368444, 96.6 seconds |
| Both existing Jido bridge suites plus `refresh_bridge_test.exs`, via `mix coveralls.json --output-dir cover/jrg9-refresh-bridge` | **190 tests, 0 failures**, seed 109546, 15.6 seconds |
| Full repository `mix test`, bounded to 900 seconds | **Completed in 580.0 seconds**, seed 812387: 48 doctests, 114 properties, 9090 tests, **8 failures**, 1 skipped, 83 excluded; exit 2 |
| Four full-suite failing files rerun, `--seed 812387`, on current code | **129 tests, 6 failures, 1 skipped**, 8.7 seconds |
| Same four files/seed with only this refresh patch temporarily reverted to the preceding `.9` state | **129 tests, same 6 failures, 1 skipped**, 15.6 seconds; refresh patch then restored and revalidated |
| `npm test -- --project=journeys-chromium specs/system_config.spec.js specs/channels.spec.js`, from `test/e2e` | Bootstrap/assets/DB completed; **56 passed**, 1.2 minutes, zero retries |
| `mix format`, `mix q`, `git diff --check` | **Passed**; docs generated and Credo reported no issues across 1224 source files / 15643 modules/functions |

The full repository run preceded addition of the final missing-client boundary test;
application behavior was identical. No failures were filtered, skipped or fixed merely
to make the global suite green. The standard full run excludes its configured
integration/ParadeDB/real-browser tags; those 83 exclusions are not additional passes.
There is no dedicated OAuth callback Playwright spec in the repository; callback and
Person OAuth controller tests passed in the focused ExUnit run. E2E here validates
the existing system-config and channel credential UI on Chromium, not provider login
or every browser project.

### Full repository failures and controlled baseline evidence

Here **baseline means the uncommitted foundation before the refresh residual patch**,
not a proven green `main` or an assertion that the foundation is ready.

| Failing location | Observed result | Classification / follow-up |
| --- | --- | --- |
| `test/zaq_web/live/bo/system/change_password_live_test.exs:55` — short password changeset error | `render_async` exceeded default 100ms | Full-suite-only; passes in both isolated comparisons. Load/order cause unresolved, not certified environment-only. `zaq-zih` |
| Same file `:232` — unreachable portal skips consent | No `/bo/dashboard` redirect within 1000ms | Same classification, `zaq-zih` |
| `test/zaq/ingestion/ingest_worker_test.exs:612` — chunk child-job pipeline | `ingested_chunks` 0, expected 2 | Reproduces before and after residual patch. Existing foundation changed Oban test mode from inline to manual; test still expects child work to run automatically. `zaq-jf6` |
| Same file `:765` — requeue failed final chunks | Chunk remains `pending`, expected `completed` | Same baseline/test-mode mismatch, `zaq-jf6` |
| `test/zaq/ingestion/ingestion_test.exs:770` — retry failed job | Processor mock expected once, called zero times | Same baseline/test-mode mismatch, `zaq-jf6` |
| Same file `:790` — retry completed-with-errors chunks | Job remains `pending`, expected processing/completed | Same baseline/test-mode mismatch, `zaq-jf6` |
| `test/zaq/engine/connect_token_edge_cases_test.exs:157` — provider missing access token | `:invalid_refresh_response`, expected old nested `{:invalid_token_payload, :missing_access_token}` | Reproduces before and after residual patch; prior claimed-refresh safe-error contract mismatch. `zaq-q1v` |
| Same file `:129` — token encryption failure | `:authentication_required`, expected Ecto changeset | Reproduces before and after residual patch. Global invalid key makes reloaded client material unreadable before HTTP; does not reach the persistence failure the old test intended. `zaq-q1v` |

At this stage these six deterministic failures were outstanding foundation
compatibility work. They were subsequently fixed and fully verified in the final
foundation pass above; the red run is retained as regression evidence.

### Updated measured coverage

The final focused run measures Connect **214/221 = 96.83%**, DataSourceBridge
**262/270 = 97.04%**, Channels.Api **204/227 = 89.87%**. As before, the broad report
omits the main Jido bridge, so its separate actual measurement is authoritative:
**913/1184 = 77.11%**, 271 missed. Every relevant line in the refresh execution and
new explicit/legacy credential helper region was exercised, including invalid IDs.
Existing whole-file exceptions remain **`zaq-fja`** (bridge) and **`zaq-lmv`** (API).
There are no new coverage exclusions. Historical measurements below describe the
initial five-finding pass, not the newer refresh measurement.

Logs are retained under
`/var/folders/9p/mdzhcqxx7hs8bw_10vwjvfp00000gn/T/opencode/`:

- `jrg9-refresh-focused-final.log`
- `jrg9-refresh-bridge-coverage.log`
- `jrg9-full-repository.log`
- `jrg9-failed-files-current.log`
- `jrg9-failed-files-pre-refresh-baseline.log`
- `jrg9-e2e-system-config-channels.log`

This intermediate pass left `.9` in progress with a red full-suite gate. The final
foundation pass above supersedes that result; independent review and coverage
exception acceptance still remain.

## Initial five reviewed findings

| Finding | Correction | Real regression evidence |
| --- | --- | --- |
| Bound OAuth credential A borrowed channel credential B's scopes/secret | Canonical authorize/exchange set trusted `oauth_credentials: :explicit` in event opts. Channels passes it as bridge context; Jido uses only explicit client settings, including nil secret and empty scopes. Legacy retains channel fallback. | `JidoConnectBridgeCoverageGapsTest`: **canonical OAuth uses bound A settings while legacy still falls back to channel B**. Real OAuth → NodeRouter → Channels → DataSourceBridge → Jido/provider path with distinct persisted A/B. Original returned `broad` instead of `read`. Tests narrow and empty scopes, explicit A secret, absent A secret and legacy B exchange. Google rejects a nil secret before HTTP; that expected rejection must not be turned into success by borrowing B. |
| Reconciliation deleted healthy claimed attempts | Maintenance removes expired attempts or missing literal owners, not all claims. Claimed encrypted columns are already cleared. | `OAuthAttemptsConcurrencyTest`: **claim commits before HTTP, concurrent replay loses; reconcile_claimed rechecked before save** runs the actual scheduled worker during blocked provider HTTP. Original callback returned `:invalid_attempt`; now finishes successfully. Existing delete/merge/inactive-Person schedules still prevent late writes. `PersonReconciliationTest` retains live claims and deletes them exactly at expiry, including an already-expired claim. |
| Resolver used pre-HTTP time for final expiry | Final locked validation evaluates current time after locks. Explicit DateTime stays fixed; function/default clocks advance. | `CredentialResolverConcurrencyTest`: **final OAuth validation reevaluates function clock for configuration expiry** and **…for grant expiry**. Configuration expires during HTTP; refreshed grant expires after its commit, before final resolution. Both reject with `:credential_expired`. A mutation check restoring captured-time behavior made both return an incorrect success; restored fix passes. |
| Callback `expires_in` crashed with function `now` | Extract existing timestamp/function evaluation into `DateUtils.now/1`; OAuth, attempts, resolver, refresh and mutation paths share it. | `OAuthAttemptsTest`: **expires_in uses the latest function clock after the provider response** advances the clock by 30 seconds; stored expiry is start + 3630. Original returned `:oauth_failed`. `DateUtilsTest` separately checks fixed/live/default clock semantics. |
| Legacy stale canonical revoke emitted old owner | Legacy `Connect.revoke_grant/1` rejects canonical schemas with `:canonical_grant_requires_owner`. Canonical callers must name current ownership through the existing API. | `PersonConnectLifecycleTest`: **legacy revoke rejects a stale canonical grant after real merge; bound revoke targets survivor**. Original legacy call succeeded with loser ID. Now no mutation/event occurs; owner-bound revoke erases survivor material and emits only survivor identity. Existing legacy revoke/event tests pass. |

No new provider registry, endpoint rules, opaque-params inspection outside the owning
bridge, revision field, completion-status field or consumer invalidation path was added.

## Consolidated integration acceptance

The acceptance suite is the following real context/DB/routing tests, not just the new
story test. HTTP, time and delivery failures use existing external seams.

| Contract | Acceptance tests |
| --- | --- |
| Optional Alice personal / Bob org; revoke differs from remove; transition to required; merge owner; safe jobs | New `FoundationAcceptanceTest`: **optional to required lifecycle keeps ownership, write-only material and event dependencies aligned** |
| Disabled/optional/required × personal/global absent/active/revoked/expired × Person/non-Person | `CredentialResolverTest`'s 96 generated `matrix person=… policy=… personal=… global=…` cases assert selected grant/owner/authentication or exact error |
| Required with and without org; malformed, inactive, deleted and aliased identity; selected failure never falls back | Same resolver matrix, **literal active identity is required before even disabled policy**, **selected personal never falls back: …**, and resolver concurrency schedules |
| Generic API key/OAuth/JWT authentication, redacted inspection and forbidden public access | `credential_resolver_test.exs`, `credential_resolver_jwt_test.exs`, `confidential_event_test.exs` |
| Trusted Person boundary, write-only DTOs, malicious keys/metadata, retained disabled own grants | `PersonCredentialsTest`: **typed trusted backend input rejects actor maps, flags, BO identities and flat legacy IDs**, **write-only API key replacement and own status never disclose global or other owners**, material-key properties and disabled cleanup cases |
| Current-slot uniqueness and rollback | `canonical_concurrency_test.exs`, `canonical_storage_test.exs`, `mutation_concurrency_test.exs`, `person_credentials_concurrency_test.exs` |
| OAuth setup/reconnect, opaque state, sensitive routing, provider error redaction, cancellation | `oauth_attempts_test.exs`, `oauth_attempts_concurrency_test.exs`, `oauth_attempts_transaction_test.exs`, callback/controller suites |
| Refresh rotation/retention, no resurrection, single flight, bounded recovery, real legacy org/user refresh | `refresh_test.exs`, `refresh_concurrency_test.exs`, `refresh_recovery_test.exs`, `grant_refresh_worker_test.exs` |
| Deterministic merge, deletion, orphan cleanup, live versus expired attempts | `person_connect_lifecycle_test.exs`, `person_lifecycle_concurrency_test.exs`, `person_lifecycle_transaction_test.exs`, `person_reconciliation_test.exs` |
| Atomic event jobs, rollback, real routing, retry UUIDs, unsupported receiver truthfully reported | `mutation_events_test.exs`, `mutation_event_transaction_test.exs`, `mutation_event_worker_test.exs`; notably **default routing reaches actual unsupported Agent action and workflow stream contains only safe payload** |
| Existing org/user resource consumers unchanged | Connect legacy tests plus full Channels, Accounts, router and callback/controller directories/files below |

Events remain dependency notifications, not successful distributed consumer invalidation.
The existing real-router test explicitly observes the unsupported Agent action. A later
consumer must reread through the actual resolver; `.9` does not fake a subscriber.

## Validation evidence

- Initial regression batch: 2 properties, 60 tests, **5 failures**, before production
  edits (two clock cases, callback clock, live reconciliation, stale revoke).
- Separate original real-bridge A/B regression: **1 failure**, `broad` versus `read`.
- Corrected focused regression batch: 2 properties, 88 tests, **0 failures**.
- Full focused test run: **29 properties, 2016 tests, 0 failures**.
- Added lifecycle story and DateUtils tests: **3 tests, 0 failures**.
- Full focused coverage run including those additions: **29 properties, 2019 tests,
  0 failures**.
- Captured-time mutation check: **2 expected failures**, each incorrectly returning
  a resolved credential. Mutation was reverted.
- Isolated existing bridge suites: **183 tests, 0 failures**, seed 134431.
- `mix format` and `mix q` passed after alias corrections. `mix q` generated docs and
  reported **no issues** across 1223 source files; it is not the full test suite.
- `git diff --check` passed.

Full focused command (coverage uses `mix coveralls.json` with the same arguments):

```sh
mix test test/zaq/engine/connect test/zaq/engine/connect_test.exs \
  test/zaq/accounts test/zaq/channels \
test/zaq/node_router_test.exs test/zaq/confidential_event_test.exs \
  test/zaq_web/controllers/channels_controller_test.exs \
  test/zaq_web/controllers/person_oauth_callback_test.exs \
  test/zaq/utils/date_utils_test.exs
```

Coverage outputs are local ignored artifacts: `cover/excoveralls.json` and
`cover/jrg9-bridge/excoveralls.json`. The latter was generated with
`mix coveralls.json --output-dir cover/jrg9-bridge` and both existing
`jido_connect_bridge*_test.exs` files. The broad run omitted the main bridge from its
JSON, so only its separate measured result is used; absence is not treated as coverage.
The broad coverage run logged background Sandbox/MCP connection errors but all tests
passed. The existing unavailable `license_manager` configuration warning also remains.

## Application files edited by `.9` and whole-file coverage

| File | Covered / relevant | Coverage |
| --- | ---: | ---: |
| `lib/zaq/channels/api.ex` | 204 / 227 | **89.87%** |
| `lib/zaq/channels/data_source_bridge.ex` | 262 / 270 | 97.04% |
| `lib/zaq/channels/jido_connect_bridge.ex` (isolated) | 909 / 1180 | **77.03%** |
| `lib/zaq/engine/connect.ex` | 213 / 220 | 96.82% |
| `lib/zaq/engine/connect/credential_resolver.ex` | 127 / 128 | 99.22% |
| `lib/zaq/engine/connect/mutations.ex` | 149 / 150 | 99.33% |
| `lib/zaq/engine/connect/oauth.ex` | 149 / 150 | 99.33% |
| `lib/zaq/engine/connect/oauth_attempts.ex` | 111 / 113 | 98.23% |
| `lib/zaq/engine/connect/person_lifecycle.ex` | 62 / 64 | 96.88% |
| `lib/zaq/engine/connect/refresh.ex` | 83 / 85 | 97.65% |
| `lib/zaq/utils/date_utils.ex` | 6 / 6 | 100.00% |

Other foundation changed application files measured in that run: People 97.08%,
PersonMerger 100%, Grant 100%, GrantRefreshWorker 100%, MutationEvents 97.83%,
MutationEventWorker 100%, OAuthAttempt 100%, PersonCredentials 100%,
SecretReconciliationWorker 100%, NodeRouter 98.73%, ChannelsController 97.73%.
ResolvedCredential has no executable lines in ExCoveralls; its security behavior is
asserted through resolver tests rather than assigning it a fabricated percentage.

### Explicit coverage exceptions and follow-up

- **JidoConnectBridge:** 271 missed lines across the existing large bridge. The new
  explicit-credential clause ran six times and the explicit-scope branch twice; legacy
  fallback ran 27 times. Existing missed OAuth branches include default-scope fallback,
  malformed credential-fetch response and list/invalid scope normalization; the wider
  missed surface includes provider/watch/sheets/error paths. Risk: untested legacy
  branches remain, despite the new ownership regression being exercised. Continue
  existing **`zaq-fja`** with real bridge suites/external controls to reach 95%; no
  exclusion or production test hook was introduced.
- **Channels.Api:** 23 missed lines: `298,299,308,312,440,444,598,599,633,637,642,652,653,
  665,736,738,739,749,752,780,804,806,913`. These are existing list/watch/default-scopes,
  conversation identity, capability, HTTP/error and fallback paths, not the two edited
  OAuth forwarding lines. Risk: unrelated routing variants are not proven by this
  focused run. **`zaq-lmv`** tracks exact branches and the >=95% follow-up.

Both exceptions require parent acceptance; the whole-file 95% gate is not declared met.

## Remaining `.9` and delivery gates

1. Parent reviewers recheck the five fixes and accept or reject the two measured
   whole-file coverage exceptions. `.9` remains in progress.
2. Full repository validation is now green after the final repairs above. Parent
   foundation requirements/PRD traceability and review sign-off remain; this report
   claims only the explicit acceptance assertions and checks recorded here.
3. Later AI rollout must migrate global grants before Connect-only runtime reads,
   subscribe every Agent-owning node, track only credential/person/grant dependencies,
   stop/recreate lazily and solve the creation-versus-mutation race. Queue activation
   needs fanout, retry/backlog retention and replay decisions.
4. Authenticated Person transport/session and UI remain separate delivery gates.
   Literal-identity/no-FK orphan races, bounded reconciliation and no synchronous
   erasure guarantee remain as documented in `engine.md`.
