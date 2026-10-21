# Persisted tool-step continuity — local branch review

- Branch: `feat/persisted-tool-step-continuity`
- PR: none opened; review covers the working-tree increment relative to `c51619911`.
- Tracking: Beadwork `zaq-v99`, implementation `.1`–`.5`, `.9`–`.13`, UX gate `.6`, browser acceptance `.7`, validation `.8`.
- Context: user approved trace-based persistence without duplicate snapshots or a mandatory history `tool_steps` field; authorized readers receive public steps, private evidence retains its separate boundaries. Subsequent UI and mobile changes received explicit approval.

## A — Inline review comments

No outstanding actionable findings.

## B — General review comments

No outstanding actionable findings. The E2E process identified and fixed missing main-app timer registration and loss of client-owned collapsed layout state; neither is left as an exception.

## C — Final recap

### Verdict

**Approve the corrected local implementation for a fresh coverage attempt.** The original review missed the history failure-test migration and lost malformed-response guard; its zero-findings assessment was incomplete. The fixes and regression evidence below supersede that assessment. This is a local code review, not external PR approval, authorization to land, or completion of the final validation gate.

### Assessment

The implementation extends existing trace serialization/finalization and reuses exact persisted answer associations. It does not add storage or invent historical invocation identities. Public projection filters private fields, preserves normalized ordering/outcomes and handles legacy evidence conservatively. Authorized BO refresh rechecks existing owner/share/admin policy; canonical transcript projections remain unchanged. Execution evidence lookup is batched, with the same root/owner relationship reused by privileged history inspection.

Live/final/reloaded rendering uses the existing message identity and shared public contract. Viewer-local elapsed time is explicitly approximate, monotonic, unpersisted and cleaned up at termination/disconnection/destruction. The responsive change remains scoped to chat; the shared DOM callback preserves only existing client-owned sidebar collapse classes. The main application opts into the timer explicitly rather than activating unrelated dormant hooks.

### Findings summary

- High: 0
- Medium: 0
- Low: 0
- Inline comments: 0
- General actionable comments: 0

### Coverage of this review

- Inspected the epic/child descriptions, recorded user decisions, implementation comments and acceptance results. No linked GitHub issue or PR was supplied for this increment.
- Reviewed the tracked runtime/presentation diff and new evidence/timer/layout modules, Storybook examples, regression/property tests, browser runner and documentation updates.
- Checked authorization, exact answer ownership, legacy omission/unknown semantics, replay and terminal settlement, artifact identity retention, public-field privacy, service ownership, batching, message reconciliation, timer lifecycle, reduced motion, responsive layout and test-only infrastructure boundaries.
- Evidence before numerical coverage: focused runtime tests/properties passed; latest layout/component/ChatLive regression run passed 114 tests; 9 timer/layout Node unit tests passed; all three browser engines passed both 1280px and 390px journeys; assets build and `mix q` passed.
- Numerical coverage and final `mix precommit` are still separate, outstanding validation gates. Existing full-suite issues must be reported rather than hidden or bypassed.

### Token usage

Exact per-review token metrics are unavailable. Estimated review-only input: 12,000 tokens; output: 700 tokens; total: 12,700 tokens. These estimates exclude the preceding implementation session and are not runtime measurements.

## Coverage gate follow-up

The subsequent fresh `mix coveralls.json` invocation was interrupted after roughly
ten minutes and reported failing tests. No successfully completed report was
confirmed; no old report was used, and neither `mix coverup` nor final
`mix precommit` was run. This prevents final validation/landing approval.

Retained diagnostics identified mismatches in:

- `test/zaq/channels/data_source_bridge_test.exs`: unsupported callback versus ambiguous connector, and unconfigured disk versus missing storage base path.
- `test/zaq/storage_test.exs`: missing disk connector versus filesystem `enoent`.
- `test/zaq_web/controllers/person_conversation_source_integration_test.exs`: expected `:materialize_document` hop versus `:data_source_get_file`.

These are reported observations, not verified baseline failures. The filtered
diagnostics did not retain every test header or the timeout's cause. Full output
must be retained during any authorized follow-up run, and coverage must be
regenerated successfully rather than inferred from an older file. A process
inspection afterward found no BEAM command line still running `coveralls.json`.

## Approved failure fixes — `zaq-v99.14`

The user reported that dropping the test database resolved unexpected baseline
connector rows and explicitly scoped this follow-up to history dispatch and source
fixtures. No database-reset procedure, storage behavior change, or weakened
assertion was introduced.

### Findings corrected

- **History command boundary:** the failure-test Router still expected separate
  `:get`/`:messages` calls, despite production using authorized `:display_history`.
  The test contract was migrated with explicit user approval. Missing ID, lookup
  failure, forbidden access, private-data rejection and opaque errors remain
  asserted at the consolidated boundary.
- **Malformed response regression:** the new success branch had lost the previous
  list guard. Reproducing tests failed with Enumerable/BadMap errors before the
  fix. Success projection now requires a Conversation with binary identity and a
  message list; malformed envelopes return `:history_unavailable` without blanket
  exception handling.
- **Source fixture inconsistency:** file creation previously used ambient default
  storage while the source could reuse an unrelated connector. A regression test
  reproduced the wrong identity. Each fixture now owns a unique connector/volume,
  resolves its directory through existing VolumeConfig/Storage APIs, and uses the
  same volume for EntryCatalog. The integration regression verifies two sources'
  real bytes through the strict existing authorization/dispatch path alongside an
  unrelated connector, without modifying that connector.
- **Existing People browser setup:** validation exposed a missing required Slack
  PersonChannel connector ID, followed by an unimplemented mock `incoming_routing`
  callback. The user separately approved both narrowly scoped repairs. Browser
  persons now reference a sandboxed Slack connector; the email mock delegates
  incoming routing to real EmailBridge semantics. All existing browser/delivery
  assertions remain intact.

### Re-review and immediate validation

Reviewed the changed boundary guard, fixture path/catalog/config identity and
cleanup, approved history scenario migration, strict actor/dispatch expectations,
and browser setup. No outstanding actionable findings in these fixes. Reuse is
local Channels validation and test orchestration over existing domain APIs; no
new Action, permission bypass or production test seam was added.

- Affected suites at seed `996479`: **25 tests, 0 failures**.
- Combined WebBridge, source and ToolHistory suites at seed `42`: **75 tests,
  3 properties, 0 failures**.
- Tool continuity: Chromium/Firefox/WebKit pass the existing 390px/1280px journeys.
- People browser: Chromium/Firefox/WebKit pass existing 390px/1280px journeys,
  including source previews, OTP, grants/session administration and logout.
- Latest `mix q` and `git diff --check`: pass.

Fresh full-suite coverage and final precommit remain separate gates; the above
results do not establish numerical coverage or authorize Git landing.

### Fresh coverage retry after fixes

The dedicated coverage workflow retried `mix coveralls.json` at seed `561338`
after the fixes and passing browser regressions. It reached its explicit
600,000 ms limit without a completed test/coverage result. Partial output included
a Finch/Jido MCP transport error, but no named ExUnit failure; whether that error
caused the timeout is unproven. Only partial output was returned, so full log
retention was not achieved. Process inspection found no surviving coverage
process. No stale report, `mix coverup`, or final `mix precommit` was used.

`zaq-v99.14` and `zaq-v99.8` retain this validation blocker. The requested history
and fixture fixes pass their focused regressions, but numerical coverage and
final approval/landing remain incomplete.

### User-confirmed coverage completion

The user subsequently reported a successful Coveralls run and explicitly stated
that no further coverage work was needed, requesting progression to the next
gate. That report supersedes the prior coverage blocker; no numerical coverage
claim is inferred here, and no older failed-run report is being reused. No further
coverage run or coverage changes are planned. Final `mix precommit` results and
human approval are tracked in `zaq-v99.8`; Git landing still needs authorization.

## Private BO history trace correction — `zaq-v99.15`

The user identified a missed regression: live BO information contained complete
execution traces, but refresh always replaced the evidence with public tool steps,
including for privileged readers. The agreed fix extends the existing history
projection, not a second evidence fetch or a parallel history endpoint.

`Conversations.display_history/2` now derives an internal `:full`/`:public` mode
from the freshly loaded persisted user after authorizing conversation access.
Both `admin` and `super_admin` retain full trace entries; other roles receive public
tool-step facts. Existing conversation visibility is unchanged, and untrusted
request flags or actor role claims cannot choose a privileged projection.
ToolHistory reuses its existing batched exact-answer relationship and execution
owner checks for either mode. The same trace field supports both the information
modal and the public tool-activity projector.

Both BO history routed hops are marked confidential. Channels and Engine reject
missing confidentiality; production-path LiveView tests verify neither history
hop enters the NodeRouter workflow broadcast stream. The widget and canonical
TranscriptHistory remain on their existing public contracts. ChannelHistoryAdmin
retains its separate privileged gate.

### Approved compatibility removal

The production persistence audit found no current writer of tool calls into
Message metadata: assistant metadata excludes it, while traces use Message or
ExecutionRecord storage. The user explicitly accepted removing metadata-only
history compatibility, including updating its tests. The persisted-history modal
now consumes only the authorized trace field, and ToolHistory drops obsolete
string/atom `tool_calls` metadata for all viewers without changing stored records.
Runtime `tool_calls` is still supported and tested; no execution behavior, stored
data, or runtime invocation projection was removed.

### Re-review and regression evidence

No outstanding actionable findings in the corrected projection, fresh role check,
conversation scope, confidential transport, or compatibility removal. The earlier
public-only history design was insufficient for privileged BO inspection; this
section supersedes that portion of the original assessment.

- Tests first reproduced canonical/legacy private trace loss, absent confidential
  flags, metadata fallback, and obsolete metadata leakage before the fixes.
- Focused history/Channels/ChatLive checks: **294 tests, 3 properties, 0 failures**.
- Expanded boundary/widget/role checks at seed `996479`: **198 tests, 14 properties,
  0 failures**.
- Real ChatLive tests remount admin and super-admin readers twice and expand the
  existing modal to verify params, results and other trace types, with unchanged
  public activity. Additional tests check stale role demotion, share revocation,
  forged roles/flags, unknown modes defaulting public, and retained database values.
- Existing Chromium, Firefox and WebKit tool-continuity journeys still pass at
  390px and 1280px. No new UI styling or substantially rewritten E2E was introduced.
- The earlier final precommit result predates this correction. Its new final gate
  and any remaining diagnostics are tracked in `zaq-v99.8` before final approval.
  No additional coverage run is claimed or planned per the user's direction.

## Follow-up: unified BO read and widget continuity — `zaq-v99.16`–`.20`

The user approved replacing the last BO initialization `:get` call with
`:display_history`, removing obsolete API read routes, and extending widget live
and canonical display history. Supplied missing/inaccessible BO IDs now fail
without replacement creation; nil-ID initialization still creates explicitly.
Engine-internal readers remain. The initial audit missed a dynamic
`get_conversation!/1` caller in ConversationDetailLive; the full suite caught that
removal regression. The domain helper and its tests are retained, avoiding a
separate screen migration and unnecessary fixture churn. Only the unused API
action routes are removed. Initialization returns no loaded evidence.

Canonical display reads authorize and page first, then resolve exact completed
root answers using batched input/answer transcript membership. Existing legacy
conversation ownership checks remain when those coordinates exist. Public facts
reuse ToolStep; agent-context defaults and private BO inspection remain unchanged.
Widget step/edit and terminal events relay optional validated snapshots.

The actual widget encoder, protocol validator, state reducer and existing activity
card are corrected in sibling `web_widget` under `ww-dtl`. Focused tests cover
streamed delivery into UI state, ordering, known and unknown outcomes, duration,
terminal non-regression, omission versus empty snapshots and history equality.
Its precommit passed **364 tests**, plus frontend unit checks and bundled build.
A local cross-project PubSub-to-Chat smoke passed **6 tests**, including real
streamed-tool and restored-terminal parity. The temporary host dependency override
and candidate-only smoke addition were removed per the user's minimal-host-change
direction; production configuration has no local-path workaround.

Affected host suites, including ConversationDetailLive, passed **284 tests and
6 properties** at seed `996479` after retaining the active domain helper;
`mix q` and whitespace checks passed. Existing BO continuity journeys passed on
all three browser engines. Existing widget response, recovery, shared-host and
conversation journeys passed **87 cases** across Chromium, Firefox and WebKit
(the initial combined run exhausted its command budget; bounded engine retries
completed successfully). No existing browser assertions were weakened, and no
new feature journey was authored before human UX approval.

**Release constraint resolved for final review — `zaq-v99.20`:** the user supplied
published widget revision `00eed1ef48e70425893d596efed9b0478a5bc426`. The host's
normal Git dependency and lockfile now select that exact revision, without a local
path override or unrelated dependency updates. The existing isolated host/widget
smoke now retains the streamed-tool regression against the installed package:
WebBridge PubSub delivery reaches actual Chat/UI state, terminal duration survives
history reopening, private extras are omitted, and late updates cannot regress it.
The prior host precommit passed 11,291 tests, 278 properties and 48 doctests; fresh
pin validation is tracked in `zaq-v99.20`. No coverage rerun or Git landing is
authorized by the pin request.

Pinned-package checks: the actual subscriber smoke passed **6 tests**; focused
host/widget/canonical-history suites passed **78 tests and 7 properties** at seed
`42`; existing Chromium/Firefox/WebKit BO continuity checks passed **3 tests**.
`mix q` passed. The dependency fetch changed only the widget lock entry. Final
precommit outcome is recorded in `zaq-v99.20` against the unchanged final files.
